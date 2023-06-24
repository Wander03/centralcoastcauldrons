CREATE OR REPLACE FUNCTION public.refresh_catalog()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
  shop_record shops%ROWTYPE;
BEGIN
  -- Fetch records from the "shops" table
  FOR shop_record IN SELECT * FROM shops LOOP
    INSERT INTO public.jobs(shop_id, job_type, tick_id)
    VALUES(shop_record.id, 'REFRESH_CATALOG', new.id);
  END LOOP;

  return new;
END;
$function$
;

CREATE TRIGGER on_insert
  AFTER INSERT ON public.ticks
  FOR EACH ROW
  EXECUTE PROCEDURE public.refresh_catalog();

DROP PROCEDURE catalog_for_shop;

CREATE OR REPLACE PROCEDURE purchase_from_shop(api_url text, api_key text, shop_id bigint, tick_id bigint, out error text)
LANGUAGE plpgsql
AS $fn$
DECLARE
  result http_response;
  url text;
  stack text;
  message text;
  cart_id text;
  catalog_purchase catalog_items%ROWTYPE;
  gold int;
  amount_purchased int;
BEGIN
  SELECT * INTO catalog_purchase FROM catalog_items WHERE catalog_items.shop_id = purchase_from_shop.shop_id AND catalog_items.tick_id = purchase_from_shop.tick_id LIMIT 1;

  if not found then
    RAISE LOG 'no catalog found';
    return;
  end if;

  BEGIN
    PERFORM http_set_curlopt('CURLOPT_TIMEOUT_MS', '10001');

    SELECT json_extract_path(content::json, 'cart_id') INTO cart_id
      FROM http((
          'POST',
           api_url || 'carts/',
           ARRAY[http_header('access_token',api_key)],
           'application/json',
           ''
        )::http_request);
  EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS stack = PG_EXCEPTION_CONTEXT, message = MESSAGE_TEXT;
      error := (message || stack);
      return;
  END;

  BEGIN
    PERFORM http_set_curlopt('CURLOPT_TIMEOUT_MS', '10001');

    url := api_url || 'carts/' || cart_id || '/items/' || catalog_purchase.sku;

    PERFORM http((
          'PUT',
           url,
           ARRAY[http_header('access_token',api_key)],
           'application/json',
           '{"quantity": 1}'
        )::http_request);
  EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS stack = PG_EXCEPTION_CONTEXT, message = MESSAGE_TEXT;
      error := (message || stack);
      return;
  END;

  BEGIN
    PERFORM http_set_curlopt('CURLOPT_TIMEOUT_MS', '10001');

    PERFORM http((
          'POST',
           api_url || 'carts/' || cart_id || '/checkout',
           ARRAY[http_header('access_token',api_key)],
           'application/json',
           ''
        )::http_request);
  EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS stack = PG_EXCEPTION_CONTEXT, message = MESSAGE_TEXT;
      error := (message || stack);
      return;
  END;

  amount_purchased := catalog_purchase.quantity;

  insert into potion_ledger_items (shop_id, tick_id, quantity_changed, potion_type)
    values (shop_id, tick_id, -1 * amount_purchased, catalog_purchase.potion_type);
  gold := amount_purchased * catalog_purchase.price;

  insert into gold_ledger_items (shop_id, tick_id, gold_changed)
    values (shop_id, tick_id, gold);
END;
$fn$;

CREATE OR REPLACE PROCEDURE catalog_for_shop(api_url text, shop_id bigint, tick_id bigint, out error text)
LANGUAGE plpgsql
AS $$
DECLARE
  result http_response;
  url text;
  stack text;
  message text;
BEGIN
  url := api_url || 'catalog/';
  BEGIN
    PERFORM http_set_curlopt('CURLOPT_TIMEOUT_MS', '10001');
    result := http_get(url);
  EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS stack = PG_EXCEPTION_CONTEXT, message = MESSAGE_TEXT;
      error := (message || stack);
      return;
  END;

  INSERT INTO http_responses (url, status, content, shop_id, tick_id)
  VALUES (url, result.status, result.content, shop_id, tick_id);
  COMMIT;

  BEGIN
  insert into catalog_items (sku, name, quantity, potion_type, tick_id, shop_id, price)
    select sku, name, quantity, potion_type, tick_id, shop_id, price
    from
    json_populate_recordset(null::record, result.content::json)
    AS
    (
        sku text,
        name text,
        quantity smallint,
        price smallint,
        potion_type vector(3)
    );
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS stack = PG_EXCEPTION_CONTEXT, message = MESSAGE_TEXT;
      error := (message || stack);
      return;
  END;

  INSERT INTO public.jobs(shop_id, job_type, tick_id)
  VALUES(shop_id, 'PURCHASE_POTIONS', tick_id);
END;
$$;

CREATE OR REPLACE PROCEDURE run_jobs()
LANGUAGE plpgsql
AS $$
DECLARE
  job jobs%ROWTYPE;
  shop shops%ROWTYPE;
  error_message text;
  counter integer := 0;
BEGIN
  while counter < 5 loop
    counter := counter + 1;
    raise log 'Counter %', counter;
    SELECT * INTO job FROM jobs WHERE success IS NULL ORDER BY created_at LIMIT 1;

    if not found then
      raise LOG 'No jobs to execute.';
      return;
    end if;

    SELECT * INTO shop FROM shops WHERE id = job.shop_id;

    error_message := null;

	  case 
		  when job.job_type = 'REFRESH_CATALOG' then
        CALL catalog_for_shop(shop.api_url, job.shop_id, job.tick_id, error_message);
      when job.job_type = 'PURCHASE_POTIONS' then
        CALL purchase_from_shop(shop.api_url, shop.api_key, job.shop_id, job.tick_id, error_message);
      else
        error_message := ('Unknown job type: ' || job.job_type);
    end case;  
    
    if error_message is null then
      UPDATE jobs SET success = TRUE WHERE id = job.id;
    else
      UPDATE jobs SET success = FALSE, error = error_message where id = job.id;
    end if;
    COMMIT;
  end loop;
END;
$$;

CREATE EXTENSION vector;
DROP TABLE potion_ledger_items;

create table
  public.gold_ledger_items (
    id bigint generated by default as identity not null,
    created_at timestamp with time zone null default now(),
    shop_id bigint not null,
    tick_id bigint not null,
    gold_changed smallint not null,
    constraint gold_ledger_items_pkey primary key (id),
    constraint gold_ledger_items_shop_id_fkey foreign key (shop_id) references shops (id),
    constraint gold_ledger_items_tick_id_fkey foreign key (tick_id) references ticks (id)
  ) tablespace pg_default;


create table
  public.barrel_ledger_items (
    id bigint generated by default as identity not null,
    created_at timestamp with time zone null default now(),
    shop_id bigint not null,
    tick_id bigint not null,
    liters_changed smallint not null,
    potion_type vector(3) not null,
    constraint barrel_ledger_items_pkey primary key (id),
    constraint barrel_ledger_items_shop_id_fkey foreign key (shop_id) references shops (id),
    constraint barrel_ledger_items_tick_id_fkey foreign key (tick_id) references ticks (id)
  ) tablespace pg_default;

create table
  public.potion_ledger_items (
    id bigint generated by default as identity not null,
    created_at timestamp with time zone null default now(),
    shop_id bigint not null,
    tick_id bigint not null,
    quantity_changed smallint not null,
    potion_type vector(3) not null,
    constraint potion_ledger_items_pkey primary key (id),
    constraint potion_ledger_items_shop_id_fkey foreign key (shop_id) references shops (id),
    constraint potion_ledger_items_tick_id_fkey foreign key (tick_id) references ticks (id)
  ) tablespace pg_default;

DROP TABLE jobs;

  create table
  public.jobs (
    id bigint generated by default as identity not null,
    created_at timestamp with time zone null default now(),
    shop_id bigint null,
    job_type text null,
    success boolean null,
    error text null,
    tick_id bigint not null default '1'::bigint,
    constraint jobs_pkey primary key (id),
    constraint jobs_shop_id_fkey foreign key (shop_id) references shops (id)
  ) tablespace pg_default;

  DROP TABLE catalog_items;
  
  create table
  public.catalog_items (
    id bigint generated by default as identity not null,
    created_at timestamp with time zone null default now(),
    sku text null,
    name text null,
    quantity smallint not null,
    potion_type vector(3) not null,
    price smallint not null,
    tick_id bigint not null,
    shop_id bigint not null default '1'::bigint,
    constraint catalog_shop_id_fkey foreign key (shop_id) references shops (id),
    constraint catalog_tick_id_fkey foreign key (tick_id) references ticks (id)
  ) tablespace pg_default;

  create table
  public.http_responses (
    id bigint generated by default as identity not null,
    created_at timestamp with time zone null default now(),
    status integer null,
    content text null,
    url text not null,
    shop_id bigint null,
    tick_id bigint null,
    constraint http_responses_pkey primary key (id),
    constraint http_responses_shop_id_fkey foreign key (shop_id) references shops (id),
    constraint http_responses_tick_id_fkey foreign key (tick_id) references ticks (id)
  ) tablespace pg_default;

  create table
  public.shops (
    id bigint generated by default as identity not null,
    created_at timestamp with time zone null default now(),
    api_url text not null,
    shop_name text not null,
    student text null,
    api_key text null,
    section text null,
    constraint shops_pkey primary key (id)
  ) tablespace pg_default;

  
create table
  public.ticks (
    id bigint generated by default as identity not null,
    created_at timestamp with time zone null default now(),
    constraint ticks_pkey primary key (id)
  ) tablespace pg_default;

create trigger on_insert
after insert on ticks for each row
execute function refresh_catalog ();

