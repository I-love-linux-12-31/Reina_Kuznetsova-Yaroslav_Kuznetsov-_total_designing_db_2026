-- FOOD-107. Зарплата курьеров courier_salary()
--
-- BR-10.2: ночью в последний день месяца для каждого курьера:
--   1. число доставленных заказов за текущий месяц;
--   2. зарплата = коэффициент текущего месяца × SUM(commission) доставленных
--      заказов курьера за текущий месяц (BR-10.5: только 'доставлен');
--   3. коэффициент на следующий месяц: 0–150 → 0.1, 151–250 → 0.2,
--      251–500 → 0.3, > 500 → 0.5;
--   4. запись в courier_pay (год, месяц, курьер, сумма, применённый коэффициент);
--   5. courier.coefficient := новый коэффициент.
--
-- Решения:
--   * «Каждый курьер» — каждый, кто нанят не позже конца месяца. Курьер без
--     доставок получает запись с amount = 0 и коэффициент 0.1 на след. месяц.
--   * Уволенный (status = 'уволен' или dismissal_date не позже конца месяца)
--     получает зарплату за месяц, но коэффициент ему не меняется (BR-10.6).
--   * Месяц заказа — по order_timestamp (так же, как в insert_test_data и
--     в отчёте how_much_money), чтобы выплаты и отчёт сходились.
--   * Повторный вызов в том же месяце: запись обновляется (ON CONFLICT по PK
--     courier_pay, BR-10.3), дубликата нет. Коэффициент текущего месяца
--     берётся из уже существующей записи (coefficient_used), а не из
--     courier.coefficient: после первого запуска там уже коэффициент на
--     СЛЕДУЮЩИЙ месяц, и повторный расчёт по нему завысил/занизил бы
--     зарплату. Так процедура идемпотентна: при тех же заказах повторный
--     вызов ничего не меняет, а при новых доставках — корректно пересчитывает.



set search_path to kuznetsova_food, exts;


create or replace procedure courier_salary()
language plpgsql
set search_path to kuznetsova_food
as $$
declare
    c_month_start constant date     := date_trunc('month', current_date)::date;
    c_next_month  constant date     := (c_month_start + interval '1 month')::date;
    c_year        constant smallint := extract(year  from c_month_start)::smallint;
    c_month       constant smallint := extract(month from c_month_start)::smallint;
    v_paid        bigint;
    v_updated     bigint;
begin
    with delivered as (                       -- доставки текущего месяца по курьерам
        select o.courier_id,
               count(*)          as delivered_cnt,
               sum(o.commission) as commission_sum
          from "order" o
         where o.status = 'доставлен'
           and o.order_timestamp >= c_month_start
           and o.order_timestamp <  c_next_month
         group by o.courier_id
    ),
    calc as (
        select c.courier_id,
               coalesce(cp.coefficient_used, c.coefficient)  as coef_current,
               coalesce(d.delivered_cnt, 0)                  as delivered_cnt,
               coalesce(d.commission_sum, 0)                 as commission_sum,
               (c.status = 'уволен'
                or (c.dismissal_date is not null
                    and c.dismissal_date < c_next_month))   as is_dismissed
          from courier c
          left join delivered d
                 on d.courier_id = c.courier_id
          left join courier_pay cp
                 on cp.courier_id = c.courier_id
                and cp.year       = c_year
                and cp.month      = c_month
         where c.hire_date < c_next_month
    ),
    pay as (
        insert into courier_pay as cp (courier_id, year, month, amount, coefficient_used)
        select k.courier_id,
               c_year,
               c_month,
               round(k.coef_current * k.commission_sum, 2),
               k.coef_current
          from calc k
        on conflict (courier_id, year, month) do update
           set amount           = excluded.amount,
               coefficient_used = excluded.coefficient_used
        returning cp.courier_id
    ),
    coef as (
        update courier c
           set coefficient = n.new_coef
          from (select k.courier_id,
                       case
                           when k.delivered_cnt <= 150 then 0.1
                           when k.delivered_cnt <= 250 then 0.2
                           when k.delivered_cnt <= 500 then 0.3
                           else                             0.5
                       end as new_coef
                  from calc k
                 where not k.is_dismissed) n                  -- BR-10.6
         where c.courier_id = n.courier_id
        returning c.courier_id
    )
    select (select count(*) from pay),
           (select count(*) from coef)
      into v_paid, v_updated;

    raise notice 'courier_salary: %-%: выплат записано %, коэффициентов обновлено %',
                 c_year, lpad(c_month::text, 2, '0'), v_paid, v_updated;
end;
$$;

comment on procedure courier_salary() is
    'FOOD-107: зарплата курьеров за текущий месяц и коэффициент на следующий (BR-10.2); повторный вызов обновляет запись';
