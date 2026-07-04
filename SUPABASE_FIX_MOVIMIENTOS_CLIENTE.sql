-- Corrige incompatibilidades de tipos al listar movimientos del cliente.
-- Es seguro ejecutarlo varias veces.

begin;

create or replace function public.bingo_cliente_movimientos_seguro(p_token text)
returns table (
  id bigint, tipo text, monto numeric, saldo_anterior numeric,
  saldo_nuevo numeric, descripcion text, referencia text, creado_en timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
declare v_usuario_id integer;
begin
  v_usuario_id := public.bingo_usuario_por_token(p_token);
  if v_usuario_id is null then
    raise exception 'Sesion de cliente invalida' using errcode = '42501';
  end if;

  return query
    select m.id::bigint, m.tipo::text, m.monto::numeric,
           m.saldo_anterior::numeric, m.saldo_nuevo::numeric,
           m.descripcion::text, m.referencia::text, m.creado_en::timestamptz
      from public.billetera_movimientos m
     where m.usuario_id = v_usuario_id
     order by m.creado_en desc
     limit 100;
end;
$$;

revoke all on function public.bingo_cliente_movimientos_seguro(text)
  from public, anon, authenticated;
grant execute on function public.bingo_cliente_movimientos_seguro(text)
  to anon, authenticated;

notify pgrst, 'reload schema';

commit;
