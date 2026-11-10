-- FOOD-108. Отчёт «сколько денег» — представление how_much_money
--
-- Одна строка на месяц: от первого месяца с доставленными заказами до
-- последнего (BR-11.9). Месяцы без доставленных заказов присутствуют
-- с нулевыми суммами. Серия месяцев — рекурсивный CTE.
--
--   year_month          text     'YYYY-MM'
--   sum_no_commission   numeric  SUM(order_amount) доставленных заказов
--   sum_with_commission numeric  SUM(total_amount) доставленных заказов
--   commission          numeric  sum_with_commission - sum_no_commission
--   prev_commission     numeric  commission предыдущего месяца (NULL у первого)
--   commission_diff     numeric  commission - prev_commission (NULL у первого)
--   courier_pay         numeric  SUM(courier_pay.amount) за месяц
--   net_profit          numeric  commission - courier_pay
--
-- Месяц заказа — по order_timestamp: так же считается courier_pay
-- (insert_test_data, courier_salary), поэтому комиссия и выплаты курьерам
-- за один месяц относятся к одним и тем же заказам.
-- "order" читается один раз (CTE orders_m используется дважды —
-- материализуется), courier_pay — один раз.


set search_path to kuznetsova_food, exts;


create or replace view how_much_money as
with recursive
orders_m as (                                  -- доставленные заказы по месяцам
    select date_trunc('month', o.order_timestamp)::date as month_start,
           sum(o.order_amount)                          as sum_no_commission,
           sum(o.total_amount)                          as sum_with_commission
      from "order" o
     where o.status = 'доставлен'
     group by 1
),
months (month_start, last_month) as (          -- непрерывная серия месяцев
    select min(om.month_start), max(om.month_start)
      from orders_m om
    having count(*) > 0                         -- нет доставок — нет строк
    union all
    select (m.month_start + interval '1 month')::date, m.last_month
      from months m
     where m.month_start < m.last_month
),
pay_m as (                                     -- выплаты курьерам по месяцам
    select make_date(cp.year, cp.month, 1) as month_start,
           sum(cp.amount)                  as courier_pay
      from courier_pay cp
     group by 1
),
monthly as (
    select m.month_start,
           coalesce(om.sum_no_commission,   0)                                  as sum_no_commission,
           coalesce(om.sum_with_commission, 0)                                  as sum_with_commission,
           coalesce(om.sum_with_commission, 0) - coalesce(om.sum_no_commission, 0) as commission,
           coalesce(pm.courier_pay, 0)                                          as courier_pay
      from months m
      left join orders_m om on om.month_start = m.month_start
      left join pay_m    pm on pm.month_start = m.month_start
)
select to_char(mo.month_start, 'YYYY-MM')                              as year_month,
       mo.sum_no_commission,
       mo.sum_with_commission,
       mo.commission,
       lag(mo.commission) over w                                       as prev_commission,
       mo.commission - lag(mo.commission) over w                       as commission_diff,
       mo.courier_pay,
       mo.commission - mo.courier_pay                                  as net_profit
  from monthly mo
window w as (order by mo.month_start)
 order by mo.month_start;

comment on view how_much_money is
    'FOOD-108: доход сервиса по месяцам — комиссия, выплаты курьерам, чистая прибыль (BR-11.9)';
