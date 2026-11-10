-- FOOD-105. Триггер пересчёта рейтинга rating_change()
--
-- BR-9.6, BR-9.7: product.rating и restaurant.rating — среднее по отзывам
-- на сущность, пересчитывается при любом INSERT / UPDATE / DELETE отзыва.
-- Если отзывов нет — NULL. У заказа агрегата нет.
--
-- Строковый AFTER-триггер: к моменту срабатывания изменение review уже
-- видно, поэтому AVG считается по актуальному набору отзывов.
-- Пересчитываются только затронутые сущности:
--   INSERT — новая (entity_type, entity_id);
--   DELETE — старая;
--   UPDATE — старая и новая (если отзыв «переехал» на другую сущность,
--            рейтинг нужно пересчитать у обеих).
--
-- Рекурсии нет
-- (product_restaurant_guard_trg срабатывает только на UPDATE OF restaurant_id).


set search_path to kuznetsova_food, exts;


create or replace function rating_change()
returns trigger
language plpgsql
set search_path to kuznetsova_food
as $$
declare
    v_type review_entity_type;
    v_id   uuid;
begin
    for v_type, v_id in
        select e.entity_type, e.entity_id
          from (select old.entity_type, old.entity_id where tg_op in ('UPDATE', 'DELETE')
                union                                       -- union убирает дубль при UPDATE rating
                select new.entity_type, new.entity_id where tg_op in ('INSERT', 'UPDATE')
               ) as e(entity_type, entity_id)
    loop
        if v_type = 'блюдо' then
            update product p
               set rating = s.avg_rating
              from (select round(avg(r.rating), 2) as avg_rating   -- NULL, если отзывов нет
                      from review r
                     where r.entity_type = 'блюдо'
                       and r.entity_id   = v_id) s
             where p.product_id = v_id
               and p.rating is distinct from s.avg_rating;

        elsif v_type = 'ресторан' then
            update restaurant rs
               set rating = s.avg_rating
              from (select round(avg(r.rating), 2) as avg_rating
                      from review r
                     where r.entity_type = 'ресторан'
                       and r.entity_id   = v_id) s
             where rs.restaurant_id = v_id
               and rs.rating is distinct from s.avg_rating;
        end if;
        -- 'заказ': агрегированного рейтинга нет (BR-9.6)
    end loop;

    return null;   -- AFTER-триггер: возвращаемое значение игнорируется
end;
$$;

comment on function rating_change() is
    'FOOD-105: пересчитывает product.rating / restaurant.rating = round(AVG(review.rating), 2) (BR-9.6, BR-9.7)';


create trigger rating_change_trg
    after insert or update of entity_type, entity_id, rating or delete on review
    for each row
    execute function rating_change();
