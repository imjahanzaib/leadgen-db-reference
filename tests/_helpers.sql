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
-- expect_msg(sql, like_pattern, label): runs sql, passes only if it fails with a message matching the pattern.
-- Use it where several rules raise the same SQLSTATE and the test must prove WHICH one fired.
create or replace function pg_temp.expect_msg(p_sql text, p_pattern text, p_label text) returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if sqlerrm like p_pattern then raise notice 'PASS  %  [%]', p_label, sqlstate; return;
    else raise exception 'FAIL  %  expected a message like %, got % (%)', p_label, p_pattern, sqlerrm, sqlstate; end if;
  end;
  raise exception 'FAIL  %  expected an error, but the statement succeeded', p_label;
end $$;
-- run(sql): executes a statement from inside a select, so a script can build statements with format().
create or replace function pg_temp.run(p_sql text) returns void language plpgsql as $$ begin execute p_sql; end $$;
