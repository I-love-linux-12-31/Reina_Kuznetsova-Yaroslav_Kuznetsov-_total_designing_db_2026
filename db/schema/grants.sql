-- FOOD-109. Пользователь inspector и его права
--
-- Запуск — под суперпользователем
-- psql -U postgres -d <БД> -f db/schema/grants.sql
--


-- 0. Предусловия: есть схема kuznetsova_food и exts.uuid_generate_v4()
do $$
begin
    if to_regnamespace('kuznetsova_food') is null then
        raise exception 'grants.sql: в БД % нет схемы kuznetsova_food', current_database()
            using hint = 'Сначала восстановите db/foodexpress_kuznetsova.backup '
                         '(или выполните db/schema/01–11) и запускайте скрипт в той же БД.';
    end if;

    if to_regprocedure('exts.uuid_generate_v4()') is null then
        raise exception 'grants.sql: в БД % нет функции exts.uuid_generate_v4()', current_database()
            using hint = 'BR-13.3: схема exts с uuid-ossp создаётся заранее: '
                         'create schema exts; create extension "uuid-ossp" schema exts;';
    end if;
end;
$$;


-- 1. Пользователь inspector с паролем NetoSQL2025.
do $$
begin
    if not exists (select 1 from pg_roles where rolname = 'inspector') then
        create user inspector with password 'NetoSQL2025';
    else
        alter user inspector with login password 'NetoSQL2025';
    end if;
end;
$$;


-- 2. Подключение к БД.
do $$
begin
    execute format('grant connect on database %I to inspector', current_database());
end;
$$;


-- 3. ALL PRIVILEGES на схему kuznetsova_food и на все её объекты.
grant all privileges on schema kuznetsova_food to inspector;                  -- USAGE, CREATE
grant all privileges on all tables    in schema kuznetsova_food to inspector; -- 12 таблиц и how_much_money
grant all privileges on all sequences in schema kuznetsova_food to inspector; -- сейчас нет: все ID — uuid
grant all privileges on all routines  in schema kuznetsova_food to inspector; -- процедуры, функции, триггерные функции

-- enum-типы: USAGE (enum_range(), приведения ::order_status и т. п.)
do $$
declare
    v_type regtype;
begin
    for v_type in
        select t.oid::regtype
          from pg_type t
         where t.typnamespace = 'kuznetsova_food'::regnamespace
           and t.typtype in ('e', 'd', 'r')                -- enum, domain, range
    loop
        execute format('grant all privileges on type %s to inspector', v_type);
    end loop;
end;
$$;

-- объекты, которые появятся в схеме позже (созданные той же ролью, что
-- запускает этот скрипт), получат те же права автоматически
alter default privileges in schema kuznetsova_food grant all privileges on tables    to inspector;
alter default privileges in schema kuznetsova_food grant all privileges on sequences to inspector;
alter default privileges in schema kuznetsova_food grant all privileges on functions to inspector;
alter default privileges in schema kuznetsova_food grant all privileges on types     to inspector;


-- 4. exts: USAGE и EXECUTE — exts.uuid_generate_v4() стоит в DEFAULT всех ID
--    (BR-11.1) и вызывается в insert_test_data. CREATE не выдаём: exts только
--    используется, но не меняется (BR-13.3).
grant usage   on schema exts                  to inspector;
grant execute on all functions in schema exts to inspector;


-- 5. information_schema и pg_catalog. USAGE на них по умолчанию есть у PUBLIC;
--    выдаём явно, чтобы не зависеть от REVOKE … FROM PUBLIC.
--    Представления information_schema показывают только объекты, на которые
--    у пользователя есть права, поэтому SELECT выдаётся на все.
--    В pg_catalog SELECT выдаётся только на нужные проверке объекты,
--    а не на все: там есть pg_authid (хэши паролей), pg_statistic и т. п.
grant usage  on schema information_schema, pg_catalog              to inspector;
grant select on all tables in schema information_schema            to inspector;
grant select on pg_catalog.pg_tables,   pg_catalog.pg_views,
                pg_catalog.pg_indexes,  pg_catalog.pg_roles,
                pg_catalog.pg_namespace, pg_catalog.pg_class,
                pg_catalog.pg_attribute, pg_catalog.pg_type,
                pg_catalog.pg_enum,     pg_catalog.pg_constraint,
                pg_catalog.pg_index,    pg_catalog.pg_proc,
                pg_catalog.pg_trigger,  pg_catalog.pg_extension    to inspector;


-- 6. search_path по умолчанию для inspector в этой БД
do $$
begin
    execute format('alter role inspector in database %I set search_path to kuznetsova_food, exts',
                   current_database());
end;
$$;


