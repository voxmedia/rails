*   Add `ActiveRecord::Base#cache_version` to support recyclable cache keys via the new versioned entries
    in `ActiveSupport::Cache`. This also means that `ActiveRecord::Base#cache_key` will now return a stable key
    that does not include a timestamp any more.

    NOTE: This feature is turned off by default, and `#cache_key` will still return cache keys with timestamps
    until you set `ActiveRecord::Base.cache_versioning = true`. That's the setting for all new apps on Rails 5.2+

    *DHH*

*   Respect `SchemaDumper.ignore_tables` in rake tasks for databases structure dump

    *Rusty Geldmacher*, *Guillermo Iguaran*

*   Add type caster to `RuntimeReflection#alias_name`

    Fixes #28959.

    *Jon Moss*

*   Deprecate `supports_statement_cache?`.

    *Ryuta Kamizono*

*   Quote database name in `db:create` grant statement (when database user does not have access to create the database).

    *Rune Philosof*

*   Raise error `UnknownMigrationVersionError` on the movement of migrations
    when the current migration does not exist.

    *bogdanvlviv*

*   Fix `bin/rails db:forward` first migration.

    *bogdanvlviv*

*   Support Descending Indexes for MySQL.

    MySQL 8.0.1 and higher supports descending indexes: `DESC` in an index definition is no longer ignored.
    See https://dev.mysql.com/doc/refman/8.0/en/descending-indexes.html.

    *Ryuta Kamizono*

*   Fix inconsistency with changed attributes when overriding AR attribute reader.

    *bogdanvlviv*

*   When calling the dynamic fixture accessor method with no arguments it now returns all fixtures of this type.
    Previously this method always returned an empty array.

    *Kevin McPhillips*


Please check [5-1-stable](https://github.com/rails/rails/blob/5-1-stable/activerecord/CHANGELOG.md) for previous changes.
