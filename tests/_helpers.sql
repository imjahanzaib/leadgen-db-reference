-- expect(sql, sqlstate, label): runs sql, passes only if it fails with exactly that SQLSTATE.
create or replace function pg_temp.expect(p_sql text, p_state text, p_label text) returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if sqlstate = p_state then raise notice 'PASS  %  [%]', p_label, sqlstate; return;
    else raise exception 'FAIL  %  expected %, got % (%)', p_label, p_state, sqlstate, sqlerrm; end if;
  end;
  raise exception 'FAIL  %  expected error %, but the statement succeeded', p_label, p_state;
end $$;
create or replace function pg_temp.ok(p_cond boolean, p_label text) returns void language plpgsql as $$
begin
  if p_cond is true then raise notice 'PASS  %', p_label; else raise exception 'FAIL  %', p_label; end if;
end $$;
