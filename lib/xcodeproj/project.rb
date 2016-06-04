require 'fileutils'
require 'securerandom'

require 'xcodeproj/project/object'
require 'xcodeproj/project/project_helper'
require 'xcodeproj/project/uuid_generator'
require 'xcodeproj/plist'

module Xcodeproj
  # This class represents a Xcode project document.
  #
  # It can be used to manipulate existing documents or even create new ones
  # from scratch.
  #
  # An Xcode project document is a plist file where the root is a dictionary
  # containing the following keys:
  #
  # - archiveVersion: the version of the document.
  # - objectVersion: the version of the objects description.
  # - classes: a key that apparently is always empty.
  # - objects: a dictionary where the UUID of every object is associated to
  #   its attributes.
  # - rootObject: the UUID identifier of the root object ({PBXProject}).
  #
  # Every object is in turn a dictionary that specifies an `isa` (the class of
  # the object) and in accordance to it maintains a set attributes. Those
  # attributes might reference one or more other objects by UUID. If the
  # reference is a collection, it is ordered.
  #
  # The {Project} API returns instances of {AbstractObject} which wrap the
  # objects described in the Xcode project document. All the attributes types
  # are preserved from the plist, except for the relationships which are
  # replaced with objects instead of UUIDs.
  #
  # An object might be referenced by multiple objects, an when no other object
  # is references it, it becomes unreachable (the root object is referenced by
  # the project itself). Xcodeproj takes care of adding and removing those
  # objects from the `objects` dictionary so the project is always in a
  # consistent state.
  #
  class Project
    include Object

    # @return [Pathname] the path of the project.
    #
    attr_reader :path

    # @param  [Pathname, String] path @see path
    #         The path provided will be expanded to an absolute path.
    # @param  [Bool] skip_initialization
    #         Wether the project should be initialized from scratch.
    # @param  [Int] object_version
    #         Object version to use for serialization, defaults to Xcode 3.2 compatible.
    #
    # @example Creating a project
    #         Project.new("path/to/Project.xcodeproj")
    #
    # @note When initializing the project, Xcodeproj mimics the Xcode behaviour
    #       including the setup of a debug and release configuration. If you want a
    #       clean project without any configurations, you should override the
    #       `initialize_from_scratch` method to not add these configurations and
    #       manually set the object version.
    #
    def initialize(path, skip_initialization = false, object_version = Constants::DEFAULT_OBJECT_VERSION)
      @path = Pathname.new(path).expand_path
      @objects_by_uuid = {}
      @generated_uuids = []
      @available_uuids = []
      @dirty           = true
      unless skip_initialization.is_a?(TrueClass) || skip_initialization.is_a?(FalseClass)
        raise ArgumentError, '[Xcodeproj] Initialization parameter expected to ' \
          "be a boolean #{skip_initialization}"
      end
      unless skip_initialization
        initialize_from_scratch
        @object_version = object_version.to_s
      end
    end

    # Opens the project at the given path.
    #
    # @param  [Pathname, String] path
    #         The path to the Xcode project document (xcodeproj).
    #
    # @raise  If the project versions are more recent than the ones know to
    #         Xcodeproj to prevent it from corrupting existing projects.
    #         Naturally, this would never happen with a project generated by
    #         xcodeproj itself.
    #
    # @raise  If it can't find the root object. This means that the project is
    #         malformed.
    #
    # @example Opening a project
    #         Project.open("path/to/Project.xcodeproj")
    #
    def self.open(path)
      path = Pathname.pwd + path
      unless Pathname.new(path).exist?
        raise "[Xcodeproj] Unable to open `#{path}` because it doesn't exist."
      end
      project = new(path, true)
      project.send(:initialize_from_file)
      project
    end

    # @return [String] the archive version.
    #
    attr_reader :archive_version

    # @return [Hash] an dictionary whose purpose is unknown.
    #
    attr_reader :classes

    # @return [String] the objects version.
    #
    attr_reader :object_version

    # @return [Hash{String => AbstractObject}] A hash containing all the
    #         objects of the project by UUID.
    #
    attr_reader :objects_by_uuid

    # @return [PBXProject] the root object of the project.
    #
    attr_reader :root_object

    # A fast way to see if two {Project} instances refer to the same projects on
    # disk. Use this over {#eql?} when you do not need to compare the full data.
    #
    # This shallow comparison was chosen as the (common) `==` implementation,
    # because it was too easy to introduce changes into the Xcodeproj code-base
    # that were slower than O(1).
    #
    # @return [Boolean] whether or not the two `Project` instances refer to the
    #         same projects on disk, determined solely by {#path} and
    #         `root_object.uuid` equality.
    #
    # @todo If ever needed, we could also compare `uuids.sort` instead.
    #
    def ==(other)
      other && path == other.path && root_object.uuid == other.root_object.uuid
    end

    # Compares the project to another one, or to a plist representation.
    #
    # @note This operation can be extremely expensive, because it converts a
    #       `Project` instance to a hash, and should _only_ ever be used to
    #       determine wether or not the data contents of two `Project` instances
    #       are completely equal.
    #
    #       To simply determine wether or not two {Project} instances refer to
    #       the same projects on disk, use the {#==} method instead.
    #
    # @param  [#to_hash] other the object to compare.
    #
    # @return [Boolean] whether the project is equivalent to the given object.
    #
    def eql?(other)
      other.respond_to?(:to_hash) && to_hash == other.to_hash
    end

    def to_s
      "#<#{self.class}> path:`#{path}` UUID:`#{root_object.uuid}`"
    end

    alias_method :inspect, :to_s

    public

    # @!group Initialization
    #-------------------------------------------------------------------------#

    # Initializes the instance from scratch.
    #
    def initialize_from_scratch
      @archive_version =  Constants::LAST_KNOWN_ARCHIVE_VERSION.to_s
      @classes         =  {}

      root_object.remove_referrer(self) if root_object
      @root_object = new(PBXProject)
      root_object.add_referrer(self)

      root_object.main_group = new(PBXGroup)
      root_object.product_ref_group = root_object.main_group.new_group('Products')

      config_list = new(XCConfigurationList)
      root_object.build_configuration_list = config_list
      config_list.default_configuration_name = 'Release'
      config_list.default_configuration_is_visible = '0'
      add_build_configuration('Debug', :debug)
      add_build_configuration('Release', :release)

      new_group('Frameworks')
    end

    # Initializes the instance with the project stored in the `path` attribute.
    #
    def initialize_from_file
      pbxproj_path = path + 'project.pbxproj'
      plist = Plist.read_from_path(pbxproj_path.to_s)
      root_object.remove_referrer(self) if root_object
      @root_object     = new_from_plist(plist['rootObject'], plist['objects'], self)
      @archive_version = plist['archiveVersion']
      @object_version  = plist['objectVersion']
      @classes         = plist['classes']
      @dirty           = false

      unless root_object
        raise "[Xcodeproj] Unable to find a root object in #{pbxproj_path}."
      end

      if archive_version.to_i > Constants::LAST_KNOWN_ARCHIVE_VERSION
        raise '[Xcodeproj] Unknown archive version.'
      end

      if object_version.to_i > Constants::LAST_KNOWN_OBJECT_VERSION
        raise '[Xcodeproj] Unknown object version.'
      end
    end

    public

    # @!group Plist serialization
    #-------------------------------------------------------------------------#

    # Creates a new object from the given UUID and `objects` hash (of a plist).
    #
    # The method sets up any relationship of the new object, generating the
    # destination object(s) if not already present in the project.
    #
    # @note   This method is used to generate the root object
    #         from a plist. Subsequent invocation are called by the
    #         {AbstractObject#configure_with_plist}. Clients of {Xcodeproj} are
    #         not expected to call this method.
    #
    # @param  [String] uuid
    #         The UUID of the object that needs to be generated.
    #
    # @param  [Hash {String => Hash}] objects_by_uuid_plist
    #         The `objects` hash of the plist representation of the project.
    #
    # @param  [Boolean] root_object
    #         Whether the requested object is the root object and needs to be
    #         retained by the project before configuration to add it to the
    #         `objects` hash and avoid infinite loops.
    #
    # @return [AbstractObject] the new object.
    #
    # @visibility private.
    #
    def new_from_plist(uuid, objects_by_uuid_plist, root_object = false)
      attributes = objects_by_uuid_plist[uuid]
      if attributes
        klass = Object.const_get(attributes['isa'])
        object = klass.new(self, uuid)
        objects_by_uuid[uuid] = object
        object.add_referrer(self) if root_object
        object.configure_with_plist(objects_by_uuid_plist)
        object
      end
    end

    # @return [Hash] The hash representation of the project.
    #
    def to_hash
      plist = {}
      objects_dictionary = {}
      objects.each { |obj| objects_dictionary[obj.uuid] = obj.to_hash }
      plist['objects']        =  objects_dictionary
      plist['archiveVersion'] =  archive_version.to_s
      plist['objectVersion']  =  object_version.to_s
      plist['classes']        =  classes
      plist['rootObject']     =  root_object.uuid
      plist
    end

    # Converts the objects tree to a hash substituting the hash
    # of the referenced to their UUID reference. As a consequence the hash of
    # an object might appear multiple times and the information about their
    # uniqueness is lost.
    #
    # This method is designed to work in conjunction with {Hash#recursive_diff}
    # to provide a complete, yet readable, diff of two projects *not* affected
    # by differences in UUIDs.
    #
    # @return [Hash] a hash representation of the project different from the
    #         plist one.
    #
    def to_tree_hash
      hash = {}
      objects_dictionary = {}
      hash['objects']        =  objects_dictionary
      hash['archiveVersion'] =  archive_version.to_s
      hash['objectVersion']  =  object_version.to_s
      hash['classes']        =  classes
      hash['rootObject']     =  root_object.to_tree_hash
      hash
    end

    # @return [Hash{String => Hash}] A hash suitable to display the project
    #         to the user.
    #
    def pretty_print
      build_configurations = root_object.build_configuration_list.build_configurations
      {
        'File References' => root_object.main_group.pretty_print.values.first,
        'Targets' => root_object.targets.map(&:pretty_print),
        'Build Configurations' => build_configurations.sort_by(&:name).map(&:pretty_print),
      }
    end

    # Serializes the project in the xcodeproj format using the path provided
    # during initialization or the given path (`xcodeproj` file). If a path is
    # provided file references depending on the root of the project are not
    # updated automatically, thus clients are responsible to perform any needed
    # modification before saving.
    #
    # @param  [String, Pathname] path
    #         The optional path where the project should be saved.
    #
    # @example Saving a project
    #   project.save
    #   project.save
    #
    # @return [void]
    #
    def save(save_path = nil)
      save_path ||= path
      @dirty = false if save_path == path
      FileUtils.mkdir_p(save_path)
      file = File.join(save_path, 'project.pbxproj')
      Plist.write_to_path(to_hash, file)
    end

    # Marks the project as dirty, that is, modified from what is on disk.
    #
    # @return [void]
    #
    def mark_dirty!
      @dirty = true
    end

    # @return [Boolean] Whether this project has been modified since read from
    #         disk or saved.
    #
    def dirty?
      @dirty == true
    end

    # Replaces all the UUIDs in the project with deterministic MD5 checksums.
    #
    # @note The current sorting of the project is taken into account when
    #       generating the new UUIDs.
    #
    # @note This method should only be used for entirely machine-generated
    #       projects, as true UUIDs are useful for tracking changes in the
    #       project.
    #
    # @return [void]
    #
    def predictabilize_uuids
      UUIDGenerator.new(self).generate!
    end

    public

    # @!group Creating objects
    #-------------------------------------------------------------------------#

    # Creates a new object with a suitable UUID.
    #
    # The object is only configured with the default values of the `:simple`
    # attributes, for this reason it is better to use the convenience methods
    # offered by the {AbstractObject} subclasses or by this class.
    #
    # @param  [Class, String] klass
    #         The concrete subclass of AbstractObject for new object or its
    #         ISA.
    #
    # @return [AbstractObject] the new object.
    #
    def new(klass)
      if klass.is_a?(String)
        klass = Object.const_get(klass)
      end
      object = klass.new(self, generate_uuid)
      object.initialize_defaults
      object
    end

    # Generates a UUID unique for the project.
    #
    # @note   UUIDs are not guaranteed to be generated unique because we need
    #         to trim the ones generated in the xcodeproj extension.
    #
    # @note   Implementation detail: as objects usually are created serially
    #         this method creates a batch of UUID and stores the not colliding
    #         ones, so the search for collisions with known UUIDS (a
    #         performance bottleneck) is performed less often.
    #
    # @return [String] A UUID unique to the project.
    #
    def generate_uuid
      generate_available_uuid_list while @available_uuids.empty?
      @available_uuids.shift
    end

    # @return [Array<String>] the list of all the generated UUIDs.
    #
    # @note   Used for checking new UUIDs for duplicates with UUIDs already
    #         generated but used for objects which are not yet part of the
    #         `objects` hash but which might be added at a later time.
    #
    attr_reader :generated_uuids

    # Pre-generates the given number of UUIDs. Useful for optimizing
    # performance when the rough number of objects that will be created is
    # known in advance.
    #
    # @param  [Integer] count
    #         the number of UUIDs that should be generated.
    #
    # @note   This method might generated a minor number of uniques UUIDs than
    #         the given count, because some might be duplicated a thus will be
    #         discarded.
    #
    # @return [void]
    #
    def generate_available_uuid_list(count = 100)
      new_uuids = (0..count).map { SecureRandom.hex(12).upcase }
      uniques = (new_uuids - (@generated_uuids + uuids))
      @generated_uuids += uniques
      @available_uuids += uniques
    end

    public

    # @!group Convenience accessors
    #-------------------------------------------------------------------------#

    # @return [Array<AbstractObject>] all the objects of the project.
    #
    def objects
      objects_by_uuid.values
    end

    # @return [Array<String>] all the UUIDs of the project.
    #
    def uuids
      objects_by_uuid.keys
    end

    # @return [Array<AbstractObject>] all the objects of the project with a
    #         given ISA.
    #
    def list_by_class(klass)
      objects.select { |o| o.class == klass }
    end

    # @return [PBXGroup] the main top-level group.
    #
    def main_group
      root_object.main_group
    end

    # @return [ObjectList<PBXGroup>] a list of all the groups in the
    #         project.
    #
    def groups
      main_group.groups
    end

    # Returns a group at the given subpath relative to the main group.
    #
    # @example
    #   frameworks = project['Frameworks']
    #   frameworks.name #=> 'Frameworks'
    #   main_group.children.include? frameworks #=> True
    #
    # @param  [String] group_path @see MobileCoreServices
    #
    # @return [PBXGroup] the group at the given subpath.
    #
    def [](group_path)
      main_group[group_path]
    end

    # @return [ObjectList<PBXFileReference>] a list of all the files in the
    #         project.
    #
    def files
      objects.grep(PBXFileReference)
    end

    # Returns the file reference for the given absolute path.
    #
    # @param  [#to_s] absolute_path
    #         The absolute path of the file whose reference is needed.
    #
    # @return [PBXFileReference] The file reference.
    # @return [Nil] If no file reference could be found.
    #
    def reference_for_path(absolute_path)
      absolute_pathname = Pathname.new(absolute_path)

      unless absolute_pathname.absolute?
        raise ArgumentError, "Paths must be absolute #{absolute_path}"
      end

      objects.find do |child|
        child.isa == 'PBXFileReference' && child.real_path == absolute_pathname
      end
    end

    # @return [ObjectList<AbstractTarget>] A list of all the targets in the
    #         project.
    #
    def targets
      root_object.targets
    end

    # @return [ObjectList<PBXNativeTarget>] A list of all the targets in the
    #         project excluding aggregate targets.
    #
    def native_targets
      root_object.targets.grep(PBXNativeTarget)
    end

    # Checks the native target for any targets in the project that are
    # extensions of that target
    #
    # @param  [PBXNativeTarget] native target to check for extensions
    #
    #
    # @return [Array<PBXNativeTarget>] A list of all targets that are
    #         extensions of the passed in target.
    #
    def extensions_for_native_target(native_target)
      return [] if native_target.extension_target_type?
      native_targets.select do |target|
        next unless target.extension_target_type?
        host_targets_for_extension_target(target).map(&:uuid).include? native_target.uuid
      end
    end

    # Returns the native target, in which the extension target is embedded.
    # This works by traversing the targets to find those where the extension
    # target is a dependency.
    #
    # @param  [PBXNativeTarget] native target where target.extension_target_type?
    #                           is true
    #
    # @return [Array<PBXNativeTarget>] the native targets that hosts the extension
    #
    def host_targets_for_extension_target(extension_target)
      raise ArgumentError, "#{extension_target} is not an extension" unless extension_target.extension_target_type?
      native_targets.select do |native_target|
        ((extension_target.uuid != native_target.uuid) &&
         (native_target.dependencies.map(&:target).map(&:uuid).include? extension_target.uuid))
      end
    end

    # @return [PBXGroup] The group which holds the product file references.
    #
    def products_group
      root_object.product_ref_group
    end

    # @return [ObjectList<PBXFileReference>] A list of the product file
    #         references.
    #
    def products
      products_group.children
    end

    # @return [PBXGroup] the `Frameworks` group creating it if necessary.
    #
    def frameworks_group
      main_group['Frameworks'] || main_group.new_group('Frameworks')
    end

    # @return [ObjectList<XCConfigurationList>] The build configuration list of
    #         the project.
    #
    def build_configuration_list
      root_object.build_configuration_list
    end

    # @return [ObjectList<XCBuildConfiguration>] A list of project wide
    #         build configurations.
    #
    def build_configurations
      root_object.build_configuration_list.build_configurations
    end

    # Returns the build settings of the project wide build configuration with
    # the given name.
    #
    # @param  [String] name
    #         The name of a project wide build configuration.
    #
    # @return [Hash] The build settings.
    #
    def build_settings(name)
      root_object.build_configuration_list.build_settings(name)
    end

    public

    # @!group Helpers
    #-------------------------------------------------------------------------#

    # Creates a new file reference in the main group.
    #
    # @param  @see PBXGroup#new_file
    #
    # @return [PBXFileReference] the new file.
    #
    def new_file(path, source_tree = :group)
      main_group.new_file(path, source_tree)
    end

    # Creates a new group at the given subpath of the main group.
    #
    # @param  @see PBXGroup#new_group
    #
    # @return [PBXGroup] the new group.
    #
    def new_group(name, path = nil, source_tree = :group)
      main_group.new_group(name, path, source_tree)
    end

    # Creates a new target and adds it to the project.
    #
    # The target is configured for the given platform and its file reference it
    # is added to the {products_group}.
    #
    # The target is pre-populated with common build settings, and the
    # appropriate Framework according to the platform is added to to its
    # Frameworks phase.
    #
    # @param  [Symbol] type
    #         the type of target. Can be `:application`, `:framework`,
    #         `:dynamic_library` or `:static_library`.
    #
    # @param  [String] name
    #         the name of the target product.
    #
    # @param  [Symbol] platform
    #         the platform of the target. Can be `:ios` or `:osx`.
    #
    # @param  [String] deployment_target
    #         the deployment target for the platform.
    #
    # @param  [Symbol] language
    #         the primary language of the target, can be `:objc` or `:swift`.
    #
    # @return [PBXNativeTarget] the target.
    #
    def new_target(type, name, platform, deployment_target = nil, product_group = nil, language = nil)
      product_group ||= products_group
      ProjectHelper.new_target(self, type, name, platform, deployment_target, product_group, language)
    end

    # Creates a new resource bundles target and adds it to the project.
    #
    # The target is configured for the given platform and its file reference it
    # is added to the {products_group}.
    #
    # The target is pre-populated with common build settings
    #
    # @param  [String] name
    #         the name of the resources bundle.
    #
    # @param  [Symbol] platform
    #         the platform of the resources bundle. Can be `:ios` or `:osx`.
    #
    # @return [PBXNativeTarget] the target.
    #
    def new_resources_bundle(name, platform, product_group = nil)
      product_group ||= products_group
      ProjectHelper.new_resources_bundle(self, name, platform, product_group)
    end

    # Creates a new target and adds it to the project.
    #
    # The target is configured for the given platform and its file reference it
    # is added to the {products_group}.
    #
    # The target is pre-populated with common build settings, and the
    # appropriate Framework according to the platform is added to to its
    # Frameworks phase.
    #
    # @param  [String] name
    #         the name of the target.
    #
    # @param  [Array<AbstractTarget>] target_dependencies
    #         targets, which should be added as dependencies.
    #
    # @return [PBXNativeTarget] the target.
    #
    def new_aggregate_target(name, target_dependencies = [])
      ProjectHelper.new_aggregate_target(self, name).tap do |aggregate_target|
        target_dependencies.each do |dep|
          aggregate_target.add_dependency(dep)
        end
      end
    end

    # Adds a new build configuration to the project and populates its with
    # default settings according to the provided type.
    #
    # @param  [String] name
    #         The name of the build configuration.
    #
    # @param  [Symbol] type
    #         The type of the build configuration used to populate the build
    #         settings, must be :debug or :release.
    #
    # @return [XCBuildConfiguration] The new build configuration.
    #
    def add_build_configuration(name, type)
      build_configuration_list = root_object.build_configuration_list
      if build_configuration = build_configuration_list[name]
        build_configuration
      else
        build_configuration = new(XCBuildConfiguration)
        build_configuration.name = name
        common_settings = Constants::PROJECT_DEFAULT_BUILD_SETTINGS
        settings = ProjectHelper.deep_dup(common_settings[:all])
        settings.merge!(ProjectHelper.deep_dup(common_settings[type]))
        build_configuration.build_settings = settings
        build_configuration_list.build_configurations << build_configuration
        build_configuration
      end
    end

    # Sorts the project.
    #
    # @param  [Hash] options
    #         the sorting options.
    # @option options [Symbol] :groups_position
    #         the position of the groups can be either `:above` or `:below`.
    #
    # @return [void]
    #
    def sort(options = nil)
      root_object.sort_recursively(options)
    end

    public

    # @!group Schemes
    #-------------------------------------------------------------------------#

    # Get list of shared schemes in project
    #
    # @param [String] path
    #         project path
    #
    # @return [Array]
    #
    def self.schemes(project_path)
      schemes = Dir[File.join(project_path, 'xcshareddata', 'xcschemes', '*.xcscheme')].map do |scheme|
        File.basename(scheme, '.xcscheme')
      end
      schemes << File.basename(project_path, '.xcodeproj') if schemes.empty?
      schemes
    end

    # Recreates the user schemes of the project from scratch (removes the
    # folder) and optionally hides them.
    #
    # @param  [Bool] visible
    #         Wether the schemes should be visible or hidden.
    #
    # @return [void]
    #
    def recreate_user_schemes(visible = true)
      schemes_dir = XCScheme.user_data_dir(path)
      FileUtils.rm_rf(schemes_dir)
      FileUtils.mkdir_p(schemes_dir)

      xcschememanagement = {}
      xcschememanagement['SchemeUserState'] = {}
      xcschememanagement['SuppressBuildableAutocreation'] = {}

      targets.each do |target|
        scheme = XCScheme.new
        scheme.add_build_target(target)
        scheme.save_as(path, target.name, false)
        xcschememanagement['SchemeUserState']["#{target.name}.xcscheme"] = {}
        xcschememanagement['SchemeUserState']["#{target.name}.xcscheme"]['isShown'] = visible
      end

      xcschememanagement_path = schemes_dir + 'xcschememanagement.plist'
      Plist.write_to_path(xcschememanagement, xcschememanagement_path)
    end

    #-------------------------------------------------------------------------#
  end
end
