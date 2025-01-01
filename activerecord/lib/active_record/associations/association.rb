# frozen_string_literal: true

module ActiveRecord
  module Associations
    # = アクティブレコードのアソシエーション
    #
    # これはすべてのアソシエーションのルートクラスです（'+ Foo' は含まれるモジュール Foo を示します）：
    #
    #   Association
    #     SingularAssociation
    #       HasOneAssociation + ForeignAssociation
    #         HasOneThroughAssociation + ThroughAssociation
    #       BelongsToAssociation
    #         BelongsToPolymorphicAssociation
    #     CollectionAssociation
    #       HasManyAssociation + ForeignAssociation
    #         HasManyThroughAssociation + ThroughAssociation
    #
    # Active Recordにおけるアソシエーションは、アソシエーションを保持するオブジェクト（<tt>owner</tt>と呼ばれる）と
    # 関連する結果セット（<tt>target</tt>と呼ばれる）との間の仲介役です。アソシエーションのメタデータは
    # <tt>reflection</tt>に利用可能で、これは+ActiveRecord::Reflection::AssociationReflection+のインスタンスです。
    #
    # 例えば、
    #
    #   class Blog < ActiveRecord::Base
    #     has_many :posts
    #   end
    #
    #   blog = Blog.first
    #
    # の場合、<tt>blog.posts</tt>のアソシエーションはオブジェクト+blog+を<tt>owner</tt>として、
    # そのポストのコレクションを<tt>target</tt>として持ち、<tt>reflection</tt>オブジェクトは
    # <tt>:has_many</tt>マクロを表します。
    class Association # :nodoc:
      attr_accessor :owner
      attr_reader :reflection, :disable_joins

      delegate :options, to: :reflection

      def initialize(owner, reflection)
        reflection.check_validity!

        @owner, @reflection = owner, reflection
        @disable_joins = @reflection.options[:disable_joins] || false

        reset
        reset_scope

        @skip_strict_loading = nil
      end

      def target
        if @target.is_a?(Promise)
          @target = @target.value
        end
        @target
      end

      # \loaded フラグを +false+ にリセットし、\target を +nil+ に設定します。
      def reset
        @loaded = false
        @stale_state = nil
      end

      def reset_negative_cache # :nodoc:
        reset if loaded? && target.nil?
      end

      # \target をリロードし、成功したら +self+ を返します。
      # +force+ が true の場合、クエリキャッシュがクリアされます。
      def reload(force = false)
        klass.connection_pool.clear_query_cache if force && klass
        reset
        reset_scope
        load_target
        self unless target.nil?
      end

      # \target がすでに \loaded されていますか？
      def loaded?
        @loaded
      end

      # \target が読み込まれたことを主張し、\loaded フラグを +true+ に設定します。
      def loaded!
        @loaded = true
        @stale_state = stale_state
      end

      # target が関連する foreign_key が指すレコードを指していない場合、target は古いと見なされます。stale の場合、アソシエーションアクセサメソッドは target をリロードします。サブクラスに stale_state メソッドが関連する場合、実装する必要があります。
      #
      # target が読み込まれていない場合は、古いと見なされません。
      def stale_target?
        loaded? && @stale_state != stale_state
      end

      # このアソシエーションの target を <tt>\target</tt> に設定し、\loaded フラグを +true+ にします。
      def target=(target)
        @target = target
        loaded!
      end

      def scope
        if disable_joins
          DisableJoinsAssociationScope.create.scope(self)
        elsif (scope = klass.current_scope) && scope.try(:proxy_association) == self
          scope.spawn
        elsif scope = klass.global_current_scope
          target_scope.merge!(association_scope).merge!(scope)
        else
          target_scope.merge!(association_scope)
        end
      end

      def reset_scope
        @association_scope = nil
      end

      def set_strict_loading(record)
        if owner.strict_loading_n_plus_one_only? && reflection.macro == :has_many
          record.strict_loading!
        else
          record.strict_loading!(false, mode: owner.strict_loading_mode)
        end
      end

      # 可能であれば逆アソシエーションを設定します
      def set_inverse_instance(record)
        if inverse = inverse_association_for(record)
          inverse.inversed_from(owner)
        end
        record
      end

      def set_inverse_instance_from_queries(record)
        if inverse = inverse_association_for(record)
          inverse.inversed_from_queries(owner)
        end
        record
      end

      # 可能であれば逆アソシエーションを削除します
      def remove_inverse_instance(record)
        if inverse = inverse_association_for(record)
          inverse.inversed_from(nil)
        end
      end

      def inversed_from(record)
        self.target = record
      end

      def inversed_from_queries(record)
        if inversable?(record)
          self.target = record
        end
      end

      # target のクラスを返します。belongs_to の polymorphic は所有者の polymorphic_type フィールドを参照してこれを上書きします。
      def klass
        reflection.klass
      end

      def extensions
        extensions = klass.default_extensions | reflection.extensions

        if reflection.scope
          extensions |= reflection.scope_for(klass.unscoped, owner).extensions
        end

        extensions
      end

      # \target を必要に応じてロードし、返します。
      #
      # このメソッドは +find_target+ に依存しているため、抽象的です。find_target は子クラスによって提供されることが期待されています。
      #
      # \target がすでに \loaded されている場合は、それを返します。従って、+load_target+ を無条件に呼び出すことで \target を取得できます。
      #
      # ActiveRecord::RecordNotFound はメソッド内で救出され、再度投げられることはありません。プロキシは \reset され、返り値は +nil+ です。
      def load_target
        @target = find_target(async: false) if (@stale_state && stale_target?) || find_target?
        if !@target && set_through_target_for_new_record?
          reflections = reflection.chain
          reflections.pop
          reflections.reverse!

          @target = reflections.reduce(through_association.target) do |middle_target, through_reflection|
            break unless middle_target
            middle_target.association(through_reflection.source_reflection_name).load_target
          end
        end

        loaded! unless loaded?
        target
      rescue ActiveRecord::RecordNotFound
        reset
      end

      def async_load_target # :nodoc:
        @target = find_target(async: true) if (@stale_state && stale_target?) || find_target?

        loaded! unless loaded?
        nil
      end

      # @reflection と @through_reflection はスコーププロックを含むため、ダンプできません
      def marshal_dump
        ivars = (instance_variables - [:@reflection, :@through_reflection]).map { |name| [name, instance_variable_get(name)] }
        [@reflection.name, ivars]
      end

      def marshal_load(data)
        reflection_name, ivars = data
        ivars.each { |name, val| instance_variable_set(name, val) }
        @reflection = @owner.class._reflect_on_association(reflection_name)
      end

      def initialize_attributes(record, except_from_scope_attributes = nil) # :nodoc:
        except_from_scope_attributes ||= {}
        skip_assign = [reflection.foreign_key, reflection.type].compact
        assigned_keys = record.changed_attribute_names_to_save
        assigned_keys += except_from_scope_attributes.keys.map(&:to_s)
        attributes = scope_for_create.except!(*(assigned_keys - skip_assign))
        record.send(:_assign_attributes, attributes) if attributes.any?
        set_inverse_instance(record)
      end

      def create(attributes = nil, &block)
        _create_record(attributes, &block)
      end

      def create!(attributes = nil, &block)
        _create_record(attributes, true, &block)
      end

      # アソシエーションが単一レコードか複数レコードかを返します。
      def collection?
        false
      end

      private
        # リーダーとライターは一貫したエラーを表示するためにこれを呼び出します
        # アソシエーションターゲットクラスが存在しない場合
        def ensure_klass_exists!
          klass
        end

        def find_target(async: false)
          if violates_strict_loading?
            Base.strict_loading_violation!(owner: owner.class, reflection: reflection)
          end

          scope = self.scope
          if skip_statement_cache?(scope)
            if async
              return scope.load_async.then(&:to_a)
            else
              return scope.to_a
            end
          end

          sc = reflection.association_scope_cache(klass, owner) do |params|
            as = AssociationScope.create { params.bind }
            target_scope.merge!(as.scope(self))
          end

          binds = AssociationScope.get_bind_values(owner, reflection.chain)
          klass.with_connection do |c|
            sc.execute(binds, c, async: async) do |record|
              set_inverse_instance(record)
              set_strict_loading(record)
            end
          end
        end

        def skip_strict_loading(&block)
          skip_strict_loading_was = @skip_strict_loading
          @skip_strict_loading = true
          yield
        ensure
          @skip_strict_loading = skip_strict_loading_was
        end

        def violates_strict_loading?
          return if @skip_strict_loading

          return unless owner.validation_context.nil?

          return reflection.strict_loading? if reflection.options.key?(:strict_loading)

          owner.strict_loading? && !owner.strict_loading_n_plus_one_only?
        end

        # このアソシエーションのスコープ。
        #
        # 注意: association_scope は target_scope にのみ結合されます
        # scope メソッドが呼び出されたときです。これは、呼び出し時に
        # scope.scoping { ... } や unscoped { ... } といった周りの呼び出しによって
        # 実際に構築されるスコープに影響を与える可能性があるためです。
        def association_scope
          if klass
            @association_scope ||= if disable_joins
              DisableJoinsAssociationScope.scope(self)
            else
              AssociationScope.scope(self)
            end
          end
        end

        # 他のスコープ（例えば、through アソシエーションのスコープ）をマージするためにオーバーライド可能
        def target_scope
          AssociationRelation.create(klass, self).merge!(klass.scope_for_association)
        end

        def scope_for_create
          scope.scope_for_create
        end

        def find_target?
          !loaded? && (!owner.new_record? || foreign_key_present?) && klass
        end

        def set_through_target_for_new_record?
          owner.new_record? && reflection.through_reflection? && through_association.target
        end

        # 所有者に外部キーが存在する場合、target をロードできることを確認します。
        # これは、所有者が新しいレコードである場合（キーがないために）、外部キーが存在するかどうかで、target をロードできるかどうかを決定するために使用されます。
        # 現在の実装では belongs_to (通常と polymorphic) および belongs_to を通じた has_one/has_many :through アソシエーションのみで使用されます。
        def foreign_key_present?
          false
        end

        # +record+ がアソシエーションの対象オブジェクトのクラスのインスタンスでない場合、ActiveRecord::AssociationTypeMismatch を発生させます。
        # 対象オブジェクトを割り当てる直前に使用する安全チェックとして使用されます。
        def raise_on_type_mismatch!(record)
          unless record.is_a?(reflection.klass)
            fresh_class = reflection.class_name.safe_constantize
            unless fresh_class && record.is_a?(fresh_class)
              message = "#{reflection.class_name}(##{reflection.klass.object_id}) expected, "\
                "got #{record.inspect} which is an instance of #{record.class}(##{record.class.object_id})"
              raise ActiveRecord::AssociationTypeMismatch, message
            end
          end
        end

        def inverse_association_for(record)
          if invertible_for?(record)
            record.association(inverse_reflection_for(record).name)
          end
        end

        # 与えられた record の逆アソシエーションを設定する必要がある場合に true を返します。
        # このメソッドはサブクラスによってオーバーライドされます。
        def inverse_reflection_for(record)
          reflection.inverse_of
        end

        # 与えられた record の逆アソシエーションを設定する必要がある場合に true を返します。
        # このメソッドはサブクラスによってオーバーライドされます。
        def invertible_for?(record)
          foreign_key_for?(record) && inverse_reflection_for(record)
        end

        # record に foreign_key が存在する場合に true を返します。
        def foreign_key_for?(record)
          foreign_key = Array(reflection.foreign_key)
          foreign_key.all? { |key| record._has_attribute?(key) }
        end

        # 関連 state が古い場合に true を返すメソッドです。
        # サブクラスで実装する必要があるため、デフォルトでは +nil+ を返します。
        def stale_state
        end

        def build_record(attributes)
          reflection.build_association(attributes) do |record|
            initialize_attributes(record, attributes)
            yield(record) if block_given?
          end
        end

        # アソシエーションリーダーでステートメントキャッシュをスキップする場合は true を返します。
        def skip_statement_cache?(scope)
          reflection.has_scope? ||
            scope.eager_loading? ||
            klass.scope_attributes? ||
            reflection.source_reflection.active_record.default_scopes.any?
        end

        def enqueue_destroy_association(options)
          job_class = owner.class.destroy_association_async_job

          if job_class
            owner._after_commit_jobs.push([job_class, options])
          end
        end

        def inversable?(record)
          record &&
            ((!record.persisted? || !owner.persisted?) || matches_foreign_key?(record))
        end

        def matches_foreign_key?(record)
          if foreign_key_for?(record)
            record.read_attribute(reflection.foreign_key) == owner.id ||
              (foreign_key_for?(owner) && owner.read_attribute(reflection.foreign_key) == record.id)
          else
            owner.read_attribute(reflection.foreign_key) == record.id
          end
        end
    end
  end
end
