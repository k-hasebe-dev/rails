# frozen_string_literal: true

require "active_support/benchmarkable"
require "active_support/dependencies"
require "active_support/descendants_tracker"
require "active_support/time"
require "active_support/core_ext/class/subclasses"
require "active_record/log_subscriber"
require "active_record/explain_subscriber"
require "active_record/relation/delegation"
require "active_record/attributes"
require "active_record/type_caster"
require "active_record/database_configurations"

module ActiveRecord #:nodoc:
  # = Active Record
  # Active Recordオブジェクトは、属性を直接指定するのではなく、それらがリンクされているテーブル定義から推測します。
  # 属性の追加、削除、変更、またその型の変更は、直接データベース内で行います。これらの変更は、即座にActive Recordオブジェクトに反映されます。
  # 特定のActive Recordクラスを特定のデータベーステーブルに結びつけるマッピングは、ほとんどの場合自動的に行われますが、珍しいケースでは上書きすることが可能です。
  #
  # See the mapping rules in table_name and the full example in link:files/activerecord/README_rdoc.html for more insight.
  #
  # == Creation
  #
  # Active Recordは、コンストラクタのパラメータをハッシュまたはブロックとして受け入れます。
  # ハッシュ方式は、HTTPリクエストのように外部からデータを受け取る場合に特に便利です。このように動作します：
  
  # user = User.new(name: "David", occupation: "Code Artist")
  # user.name # => "David"
  # また、ブロックを使った初期化も可能です：
  
  # user = User.new do |u|
  #   u.name = "David"
  #   u.occupation = "Code Artist"
  # end
  #
  # もちろん、空のオブジェクトを作成して後から属性を設定することもできます。これは、より柔軟に属性を設定したい場合や、初期化時に属性が分からない場合に便利です。
  #
  #   user = User.new
  #   user.name = "David"
  #   user.occupation = "Code Artist"
  #
  # == Conditions
  #   #
  # 条件は、SQL文のWHERE部分を表す文字列、配列、またはハッシュとして指定できます。
  # 配列形式は、入力が汚染されていてサニタイズが必要な場合に使用します。
  # 文字列形式は、汚染されたデータを含まない文の場合に使用できます。
  # ハッシュ形式は、配列形式と似ていますが、等価条件と範囲指定のみが可能です。
  # 1. 文字列形式 (String form)
  # 用途: 生データで安全な場合や、複雑なクエリを直接記述したい場合に使用します。
  # 特徴: SQL文そのものを記述するため、柔軟性があります。ただし、ユーザー入力のような外部データを使用する場合は、SQLインジェクションのリスクがあるため注意が必要です。
  # 例
  # User.where("age > 30 AND occupation = 'Engineer'")
  # 2. 配列形式 (Array form)
  # 用途: ユーザー入力や外部から提供されたデータを使用する場合。入力データを自動的にエスケープし、SQLインジェクションを防ぎます。
  # 特徴: プレースホルダー (?) を使って値を埋め込む方法です。外部データの取り扱いに安全です。
　# 安全な形式で動的データを埋め込む
  # age = 30
  # occupation = "Engineer"
  # User.where("age > ? AND occupation = ?", age, occupation)
  # 3. ハッシュ形式 (Hash form)
  # 用途: シンプルな条件 (等価条件や範囲指定) を使いたい場合。可読性が高く、簡潔に記述できます。
  # 特徴: = (等価) と範囲指定 (BETWEEN や IN) のみ使用可能です。
  # 例
  # # 単純な等価条件
  # User.where(age: 30, occupation: "Engineer")
  
  # # 範囲条件
  # User.where(age: 20..30)
  
  # # 配列によるIN条件
  # User.where(occupation: ["Engineer", "Designer"])
  # 
  #   class User < ActiveRecord::Base
  #     def self.authenticate_unsafely(user_name, password)
  #       where("user_name = '#{user_name}' AND password = '#{password}'").first
  #     end
  #
  #     def self.authenticate_safely(user_name, password)
  #       where("user_name = ? AND password = ?", user_name, password).first
  #     end
  #
  #     def self.authenticate_safely_simply(user_name, password)
  #       where(user_name: user_name, password: password).first
  #     end
  #   end
  #
  # authenticate_unsafely メソッドは、パラメータをクエリに直接挿入するため、user_name および password パラメータがHTTPリクエストから直接送られてくる場合、SQLインジェクション攻撃に対して脆弱です。
  #  一方、authenticate_safely と authenticate_safely_simply の両方は、クエリに挿入する前に user_name と password をサニタイズするため、攻撃者がクエリを逃れてログインを偽装（またはそれ以上の悪意ある操作）することを防ぎます。
  # 条件に複数のパラメータを使用する場合、4つ目や5つ目のクエスチョンマークが何を表しているのかを正確に把握するのが難しくなることがあります。そのような場合には、名前付きバインド変数を使用することを検討できます。
  # これは、クエスチョンマークをシンボルに置き換え、対応するシンボルキーの値を持つハッシュを提供することで実現します。
  #
  #   Company.where(
  #     "id = :id AND name = :name AND division = :division AND created_at > :accounting_date",
  #     { id: 3, name: "37signals", division: "First", accounting_date: '2005-01-01' }
  #   ).first
  #
  # 同様に、ステートメントを使用しない単純なハッシュを使用すると、SQLの AND 演算子による等価性に基づいて条件が生成されます。例えば：
  # Student.where(first_name: "Harvey", status: 1)
  # Student.where(params[:student])
  # 
  # ハッシュ内で範囲を使用すると、SQL の BETWEEN 演算子を利用できます：
  # Student.where(grade: 9..12)
  # 
  # ハッシュ内で配列を使用すると、SQL の IN 演算子を利用できます：
  # Student.where(grade: [9, 11, 12])
  # 
  # テーブルを結合する際には、ネストされたハッシュや `'table_name.column_name'` 形式で記述されたキーを使用して、特定の条件のテーブル名を限定することができます。例えば：
  # 
  # Student.joins(:schools).where(schools: { category: 'public' })
  # Student.joins(:schools).where('schools.category' => 'public')
  # 
  # これらの方法により、クエリの条件を柔軟かつ明確に指定することが可能になり、コードの可読性と保守性が向上します。
  #
  # ==デフォルトアクセサの上書き
  # すべてのカラム値はActive Recordオブジェクト上で基本的なアクセサを通じて自動的に利用可能ですが、時にはこの動作を特化させたい場合があります。
  # これは、デフォルトのアクセサ（属性と同じ名前を使用）を上書きし、super を呼び出すことで実現できます
  #
  #   class Song < ActiveRecord::Base
  #     # Uses an integer of seconds to hold the length of the song
  #
  #     def length=(minutes)
  #       super(minutes.to_i * 60)
  #     end
  #
  #     def length
  #       super / 60
  #     end
  #   end
  # 
  # デフォルトアクセサの上書き
  # すべてのカラム値はActive Recordオブジェクト上で基本的なアクセサを通じて自動的に利用可能ですが、時にはこの動作を特化させたい場合があります。これは、デフォルトのアクセサ（属性と同じ名前を使用）を上書きし、super を呼び出すことで実現できます。
  # 例：デフォルトアクセサの上書き
  # class User < ActiveRecord::Base
  #   # カスタムアクセサの定義
  #   def password
  #     # パスワードを取得する前に何らかの処理を実行
  #     decrypted_password = decrypt(super)
  #     decrypted_password
  #   end
  
  #   def password=(new_password)
  #     # パスワードを設定する前に何らかの処理を実行
  #     encrypted_password = encrypt(new_password)
  #     super(encrypted_password)
  #   end
  #   private
  #   def encrypt(password)
  #     # パスワードの暗号化ロジック
  #     Digest::SHA256.hexdigest(password)
  #   end
  #   def decrypt(password)
  #     # パスワードの復号化ロジック（例として単純なハッシュを使用）
  #     password
  #   end
  # end
  # この例では、password 属性のアクセサを上書きしています。password を取得するときには復号化処理を行い、設定するときには暗号化処理を行います。super を使用することで、元のアクセサの動作を維持しつつ、追加のロジックを組み込むことができます。
  #
  # == Attribute query methods
  #
  # ## 基本的なアクセサに加えて、クエリメソッドもActive Recordオブジェクト上で自動的に利用可能です。  
  # クエリメソッドを使用すると、属性値が存在するかどうかをテストできます。  
  # さらに、数値を扱う場合、クエリメソッドは値がゼロであれば `false` を返します。
  # ---
  # 例えば、`name` 属性を持つActive RecordのUserには、ユーザーが名前を持っているかどうかを判断するために呼び出すことができる `name?` メソッドがあります：
  # user = User.new(name: "David")
  # user.name? # => true
  # anonymous = User.new(name: "")
  # anonymous.name? # => false
  # この例では、`user` オブジェクトは `name` 属性に `"David"` を持っているため、`user.name?` は `true` を返します。一方、`anonymous` オブジェクトの `name` 属性は空文字列であるため、`anonymous.name?` は `false` を返します。
  # これらのクエリメソッドを活用することで、モデルの属性値の存在や特定の条件を簡単にチェックでき、コードの可読性と保守性が向上します。
  #
  # == Accessing attributes before they have been typecasted
  #
 ## 型キャスト前のアクセサの使用
  
  # 場合によっては、カラムに基づく型キャストが実行される前に、生の属性データを読み取る必要があります。これは、すべての属性が持つ `<attribute>_before_type_cast` アクセサを使用することで実現できます。例えば、`Account` モデルに `balance` 属性がある場合、`account.balance_before_type_cast` や `account.id_before_type_cast` を呼び出すことができます。
  
  # これは特に、バリデーションの状況でユーザーが整数フィールドに対して文字列を入力し、その元の文字列をエラーメッセージに表示したい場合に有用です。通常、属性にアクセスすると文字列が `0` に型キャストされますが、これは望ましい動作ではありません。
  
  # ---
  
  # **例：型キャスト前の属性アクセス**
  
  # ```ruby
  # # Accountモデルにbalance属性がある場合
  # account = Account.new(balance: "1000")
  # account.balance_before_type_cast # => "1000"
  
  # # バリデーションエラー時に元の入力値を表示する場合
  # account = Account.new(balance: "invalid_number")
  # unless account.valid?
  #   puts "エラー: バランスには有効な数値を入力してください (入力値: #{account.balance_before_type_cast})"
  # end
  # ```
  
  # この例では、`balance_before_type_cast` メソッドを使用して、型キャストが行われる前の元の入力値を取得しています。これにより、ユーザーが入力した実際の値をエラーメッセージに表示することが可能になります。通常の `balance` アクセサを使用すると、無効な入力が `0` に型キャストされてしまいますが、
  `balance_before_type_cast` を使用することで、ユーザーが入力した元の値を保持できます。
  # 
  # ---
  # これらのアクセサを活用することで、モデルの属性値を柔軟に扱い、ユーザー入力に対する適切なフィードバックを提供することが可能になります。特に、入力の検証やエラーメッセージのカスタマイズにおいて有用です。
  #
  # == Dynamic attribute-based finders
  #
  # ## 動的属性ベースのファインダー
  # 動的属性ベースのファインダーは、SQLを使用せずに単純なクエリでオブジェクトを取得（および/または作成）するためのやや非推奨な方法です。これは、`find_by_`に属性名を付加することで機能します。例えば、`Person.find_by_user_name` のように使用します。`Person.find_by(user_name: user_name)` と書く代わりに、`Person.find_by_user_name(user_name)` を使用できます。
  # 
  # ### 動的ファインダーにエクスクラメーションマークを追加
  # 
  # 動的ファインダーの末尾に感嘆符（!）を追加することで、レコードが見つからない場合に `ActiveRecord::RecordNotFound` エラーを発生させることが可能です。例えば、`Person.find_by_last_name!` のように使用します。
  # 
  # ### 複数の属性を使用する
  # 
  # 同じ `find_by_` に複数の属性を使用することも可能で、属性名を `_and_` で区切ります。
  # 
  # Person.find_by(user_name: user_name, password: password)
  # Person.find_by_user_name_and_password(user_name, password) # 動的ファインダーを使用
  # 
  # ### リレーションやネームドスコープでの使用
  # 
  # これらの動的ファインダーメソッドは、リレーションやネームドスコープ上でも呼び出すことが可能です。
  # 
  # Payment.order("created_on").find_by_amount(50)
  # 
  # ### 補足説明
  # 
  # 動的属性ベースのファインダーは、シンプルなクエリを手軽に記述できる利点がありますが、Railsの最新バージョンでは非推奨となっており、代わりにハッシュを使用した `find_by` メソッドの利用が推奨されています。以下にその理由と推奨される方法を簡単に説明します。
  # 
  # #### 非推奨の理由
  # 
  # 1. **可読性の低下**: 属性名が増えると、メソッド名が長くなり、読みづらくなります。
  # 2. **柔軟性の欠如**: 動的ファインダーでは複雑なクエリを表現するのが難しくなります。
  # 3. **一貫性の欠如**: ハッシュを使用する方法に比べて、一貫したインターフェースを提供しません。
  # 
  # #### 推奨される方法
  # 
  # 代わりに、ハッシュを使用した `find_by` メソッドを利用することで、より柔軟で可読性の高いクエリを記述できます。
  # 
  # # 推奨される方法
  # Person.find_by(user_name: user_name, password: password)
  # 
  # # エクスクラメーションマークを使用して例外を発生させる場合
  # Person.find_by!(user_name: user_name, password: password)
  # 
  # この方法では、属性名と値を明示的に指定するため、コードの可読性とメンテナンス性が向上します。また、動的ファインダーと同様に、感嘆符を付けることでレコードが見つからない場合に例外を発生させることができます。
  # 
  # ### まとめ
  # 
  # 動的属性ベースのファインダーは、シンプルなクエリを簡単に記述できる便利な方法ですが、可読性や柔軟性の面で制約があります。最新のRailsでは非推奨となっているため、ハッシュを使用した `find_by` メソッドの利用を推奨します。これにより、コードの一貫性と可読性が向上し、よりメンテナブルなアプリケーションを構築することができます。
  #
  ## 配列、ハッシュ、およびその他のマッピング不可能なオブジェクトをテキストカラムに保存する
  
  Active Recordは、YAMLを使用してテキストカラム内の任意のオブジェクトをシリアライズ（直列化）することができます。これを行うには、クラスメソッド `{serialize}` を呼び出して指定する必要があります。これにより、追加の作業をせずに配列、ハッシュ、およびその他のマッピング不可能なオブジェクトを保存することが可能になります。
  
  ### シンプルなシリアライズの例
  # class User < ActiveRecord::Base
  #   serialize :preferences
  # end
  # user = User.create(preferences: { "background" => "black", "display" => "large" })
  # User.find(user.id).preferences # => { "background" => "black", "display" => "large" }
  # この例では、`User` モデルの `preferences` 属性にハッシュを保存しています。`serialize` メソッドを使用することで、このハッシュが自動的にYAML形式にシリアライズされ、テキストカラムに保存されます。データベースからオブジェクトを取得すると、`preferences` 属性は元のハッシュ形式で復元されます。
  
  # ### クラスオプションを使用したシリアライズ
  # クラスオプションを第二引数として指定することも可能です。これにより、シリアライズされたオブジェクトが指定されたクラスの階層内にないクラスの子孫として取得された場合に例外が発生します。
  # class User < ActiveRecord::Base
  #   serialize :preferences, Hash
  # end
  
  # user = User.create(preferences: %w( one two three ))
  # User.find(user.id).preferences    # => SerializationTypeMismatch が発生
  # この例では、`preferences` 属性を `Hash` クラスとしてシリアライズするように指定しています。そのため、`preferences` に配列を保存しようとすると、データを取得した際に `SerializationTypeMismatch` 例外が発生します。これにより、予期しないデータ型の保存を防ぐことができます。
  
  # ### クラスオプションを指定した場合のデフォルト値
  # クラスオプションを指定すると、その属性のデフォルト値は指定したクラスの新しいインスタンスになります。
  # class User < ActiveRecord::Base
  #   serialize :preferences, OpenStruct
  # end
  # user = User.new
  # user.preferences.theme_color = "red"
  # user.save
  # この例では、`preferences` 属性を `OpenStruct` クラスとしてシリアライズするように指定しています。新しい `User` オブジェクトを作成すると、`preferences` 属性は自動的に `OpenStruct` の新しいインスタンスとなります。これにより、以下のように柔軟に属性を設定することが可能です。
  # user.preferences.theme_color = "red"
  # 
  ### まとめ
  # Active Recordの`serialize`メソッドを使用することで、配列やハッシュ、その他のマッピング不可能なオブジェクトを簡単にテキストカラムに保存・復元することができます。クラスオプションを指定することで、保存されるデータの型を制約し、データの整合性を保つことも可能です。これにより、複雑なデータ構造を扱う際にも柔軟に対応でき、追加の作業をせずにデータを管理することができます。
  # ### 注意点
  # 1. **パフォーマンス**:
  #    - シリアライズされたデータはテキスト形式で保存されるため、大量のデータを扱う場合や頻繁にアクセスする場合にはパフォーマンスに影響を与える可能性があります。
  # 2. **データの可搬性**:
  #    - YAML形式で保存されたデータは、人間が読める形式ですが、異なるバージョンのRubyやRails間での互換性に注意が必要です。
  # 3. **検索の制限**:
  #    - シリアライズされたデータはデータベース内で一つのテキストとして扱われるため、特定の属性に基づいた効率的な検索やクエリが難しくなります。
  # 4. **セキュリティ**:
  #    - シリアライズされたデータにユーザー入力を含める場合、YAMLのパースに関連するセキュリティリスク（例えば、コードインジェクション）に注意が必要です。信頼できるデータのみをシリアライズするように心がけましょう。
  # ### 代替手段
  # Railsでは、シリアライズされたデータを扱う他にも、以下のような方法で複雑なデータ構造を管理することができます。
  # 1. **JSONカラムの利用**:
  #    - データベースがJSON型をサポートしている場合、JSONカラムを使用してデータを保存することができます。これにより、より効率的な検索やクエリが可能になります。
  #    class User < ActiveRecord::Base
  #      serialize :preferences, JSON
  #    end
  # 2. **関連モデルの使用**:
  #    - 配列やハッシュの内容を別のモデルとして定義し、関連付け（例えば、`has_many`）を使用して管理する方法です。これにより、データの正規化が進み、データベースの整合性とクエリの柔軟性が向上します。
  #    class User < ActiveRecord::Base
  #      has_many :preferences
  #    end
  
  #    class Preference < ActiveRecord::Base
  #      belongs_to :user
  #    end
  # これらの方法を検討することで、アプリケーションの要件に最適なデータ管理方法を選択することができます。
  #
  #
  # == Single table inheritance
  #
  # Active Record allows inheritance by storing the name of the class in a
  # column that is named "type" by default. See ActiveRecord::Inheritance for
  # more details.
  #
  ## 異なるモデルでの複数データベースへの接続

  # 接続は通常、`ActiveRecord::Base.establish_connection` を通じて作成され、`ActiveRecord::Base.connection` によって取得されます。`ActiveRecord::Base` から継承されたすべてのクラスはこの接続を使用します。しかし、クラス固有の接続を設定することも可能です。例えば、`Course` が `ActiveRecord::Base` を継承しているが、異なるデータベースに存在する場合、単に `Course.establish_connection` と指定することで、`Course` およびそのすべてのサブクラスがこの接続を使用するようになります。
  
  # ```ruby
  # class Course < ActiveRecord::Base
  #   establish_connection :courses_database
  # end
  # ```
  
  # この機能は、`ActiveRecord::Base` 内にクラスごとにインデックスされたハッシュとして接続プールを保持することで実装されています。接続が要求されると、`ActiveRecord::Base.retrieve_connection` メソッドはクラス階層を上にたどり、接続プール内で接続が見つかるまで検索します。
  
  # ### 具体例
  
  # 以下に、`Course` クラスが異なるデータベースに接続する例を示します。
  
  # ```ruby
  # # config/database.yml
  
  # default: &default
  #   adapter: postgresql
  #   encoding: unicode
  #   pool: 5
  #   username: your_username
  #   password: your_password
  
  # development:
  #   primary:
  #     <<: *default
  #     database: main_database
  
  #   courses_database:
  #     <<: *default
  #     database: courses_database
  # ```
  
  # ```ruby
  # # app/models/course.rb
  
  # class Course < ActiveRecord::Base
  #   establish_connection :courses_database
  # end
  # ```
  
  # この設定により、`Course` クラスおよびそのサブクラスは `courses_database` に接続します。一方、`ActiveRecord::Base` を継承する他のクラスは `primary` データベースに接続し続けます。
  
  # ### 接続プールの仕組み
  
  # `ActiveRecord::Base` は接続プールをハッシュとして保持しており、キーはクラス名、値は接続情報です。接続が必要になると、`retrieve_connection` メソッドが呼び出され、該当するクラスの接続がプールから取得されます。もし特定のクラスに対する接続がプールに存在しない場合、親クラス（通常は `ActiveRecord::Base`）の接続が使用されます。
  
  # ```ruby
  # # ActiveRecord::Base内部の接続プールの管理（擬似コード）
  
  # class ActiveRecord::Base
  #   @connection_pool = {}
  
  #   def self.establish_connection(spec = nil)
  #     # 接続情報を設定し、プールに追加
  #     @connection_pool[self] = Connection.new(spec)
  #   end
  
  #   def self.retrieve_connection
  #     # クラス階層を上にたどり、接続を取得
  #     klass = self
  #     while klass != Object
  #       return @connection_pool[klass] if @connection_pool.key?(klass)
  #       klass = klass.superclass
  #     end
  #     # デフォルトの接続を返す
  #     @connection_pool[ActiveRecord::Base]
  #   end
  # end
  # ```
  
  # ### 注意点
  
  # 1. **接続の明示的な管理**: 複数のデータベースに接続する場合、それぞれの接続設定を明示的に管理する必要があります。`database.yml` ファイルで各データベースの設定を適切に行いましょう。
  
  # 2. **接続の競合**: 複数のデータベースに同時に接続する場合、接続プールの設定（例えば、プールサイズ）に注意が必要です。適切なプールサイズを設定し、接続の競合や枯渇を防ぎましょう。
  
  # 3. **セキュリティ**: 異なるデータベースへの接続情報（特に認証情報）は、セキュリティ上慎重に管理する必要があります。環境変数や認証管理ツールを使用して、認証情報を安全に保管しましょう。
  
  # 4. **トランザクション管理**: 異なるデータベース間でのトランザクション管理は複雑になる可能性があります。必要に応じて、分散トランザクション管理を検討してください。
  
  # ### まとめ
  
  # Active Recordの `establish_connection` メソッドを使用することで、異なるモデルごとに異なるデータベースに接続することが可能です。この機能を活用することで、アプリケーションのスケーラビリティやデータ分散を柔軟に設計できます。ただし、複数のデータベース接続を管理する際には、接続プールの設定やセキュリティ、トランザクション管理に注意を払い、適切に設計・実装することが重要です。
  class Base
    extend ActiveModel::Naming

    extend ActiveSupport::Benchmarkable
    extend ActiveSupport::DescendantsTracker

    extend ConnectionHandling
    extend QueryCache::ClassMethods
    extend Querying
    extend Translation
    extend DynamicMatchers
    extend DelegatedType
    extend Explain
    extend Enum
    extend Delegation::DelegateCache
    extend Aggregations::ClassMethods

    include Core
    include Persistence
    include ReadonlyAttributes
    include ModelSchema
    include Inheritance
    include Scoping
    include Sanitization
    include AttributeAssignment
    include ActiveModel::Conversion
    include Integration
    include Validations
    include CounterCache
    include Attributes
    include Locking::Optimistic
    include Locking::Pessimistic
    include AttributeMethods
    include Callbacks
    include Timestamp
    include Associations
    include ActiveModel::SecurePassword
    include AutosaveAssociation
    include NestedAttributes
    include Transactions
    include TouchLater
    include NoTouching
    include Reflection
    include Serialization
    include Store
    include SecureToken
    include SignedId
    include Suppressor
  end

  ActiveSupport.run_load_hooks(:active_record, Base)
end
