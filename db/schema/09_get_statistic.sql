-- FOOD-106. Статистика по ресторанам get_statistic()
--
-- Колонки — контракт бэкенда (BR-13.2): restaurant_name, best_product_name,
-- total_amount, avg_amount, best_user.
-- Учитываются только заказы со статусом 'доставлен'. Одна строка на ресторан,
-- в том числе на ресторан без доставленных заказов: total_amount = 0,
-- avg_amount / best_product_name / best_user = NULL.
--
-- Оптимизация (BR-11.8):
--   * каждая таблица читается один раз: "order" — в CTE delivered (он
--     используется дважды и потому материализуется), order_structure,
--     product, client, restaurant — по одному разу в соединениях;
--   * нет оконных функций и коррелированных подзапросов/LATERAL — только
--     JOIN и GROUP BY;
--   * «лучшее» значение в группе (argmax) выбирается агрегатом
--     (array_agg(... order by метрика desc, random()))[1]: при равенстве
--     метрики порядок случайный, то есть берётся случайный из лидеров;
--   * total_amount и avg_amount считаются из уже сгруппированных по клиентам
--     данных (сумма сумм и сумма / количество), без повторного прохода.
--   best_user — client.login: ФИО клиента не хранится (BR-2.6), это
--   решение бизнеса из FOOD-106.


set search_path to kuznetsova_food, exts;


create or replace function get_statistic()
returns table (
    restaurant_name   varchar,
    best_product_name varchar,
    total_amount      numeric,
    avg_amount        numeric,
    best_user         varchar
)
language sql
set search_path to kuznetsova_food
as $$
    with delivered as (                       -- единственное чтение "order"
        select o.order_id, o.restaurant_id, o.client_id, o.total_amount
          from "order" o
         where o.status = 'доставлен'
    ),
    by_client as (                            -- ресторан × клиент
        select d.restaurant_id,
               d.client_id,
               count(*)            as orders_cnt,
               sum(d.total_amount) as amount
          from delivered d
         group by d.restaurant_id, d.client_id
    ),
    rest_orders as (                          -- ресторан: суммы и лучший клиент
        select bc.restaurant_id,
               sum(bc.amount)                                  as total_amount,
               round(sum(bc.amount) / sum(bc.orders_cnt), 2)   as avg_amount,
               (array_agg(bc.client_id
                          order by bc.orders_cnt desc, random()))[1] as best_client_id
          from by_client bc
         group by bc.restaurant_id
    ),
    by_product as (                           -- ресторан × блюдо
        select d.restaurant_id,
               os.product_id,
               sum(os.quantity) as qty
          from delivered d
          join order_structure os on os.order_id = d.order_id
         group by d.restaurant_id, os.product_id
    ),
    rest_products as (                        -- ресторан: самое покупаемое блюдо
        select bp.restaurant_id,
               (array_agg(bp.product_id
                          order by bp.qty desc, random()))[1] as best_product_id
          from by_product bp
         group by bp.restaurant_id
    )
    select r.restaurant_name,
           p.product_name                  as best_product_name,
           coalesce(ro.total_amount, 0)    as total_amount,
           ro.avg_amount,
           c.login                         as best_user
      from restaurant r
      left join rest_orders   ro on ro.restaurant_id = r.restaurant_id
      left join rest_products rp on rp.restaurant_id = r.restaurant_id
      left join product       p  on p.product_id     = rp.best_product_id
      left join client        c  on c.client_id      = ro.best_client_id
     order by r.restaurant_name, r.restaurant_id;
$$;

comment on function get_statistic() is
    'FOOD-106: по ресторану — самое покупаемое блюдо, сумма и средний чек доставленных заказов, самый частый клиент (login)';
