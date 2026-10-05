\set ON_ERROR_STOP on
\ir _helpers.sql
begin;
\echo == 06 audit log: append-only, partitioned by month, bounded by retention, records who did it
\o /dev/null
insert into auth.users (id, email) values ('11111111-6666-6666-6666-666666666666', 'owner-a@example.test');
insert into public.clients (id, name) values ('aaaaaaaa-6666-0000-0000-000000000001', 'Audit Client A');
insert into public.memberships (user_id, client_id, role) values ('11111111-6666-6666-6666-666666666666', 'aaaaaaaa-6666-0000-0000-000000000001', 'owner');

-- ------------------------------------------------------------ A. who did it
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"11111111-6666-6666-6666-666666666666","role":"authenticated"}', true);
select set_config('request.headers', '{"x-request-id":"req-abc-123","user-agent":"test"}', true);
insert into public.markets (client_id, name) values ('aaaaaaaa-6666-0000-0000-000000000001', 'Ctx-1');
reset role;
select pg_temp.ok((select actor = '11111111-6666-6666-6666-666666666666' and jwt_role = 'authenticated' and effective_role = 'authenticated'
                          and request_id = 'req-abc-123' and txid = pg_current_xact_id()::text::bigint and session_role = session_user
                   from audit.log where table_name = 'markets' and new_row ->> 'name' = 'Ctx-1'),
                  'a change through the API records the user, JWT role, effective role, request id and transaction id');

select set_config('request.headers', '{"sb-request-id":"sb-777"}', true);
insert into public.markets (client_id, name) values ('aaaaaaaa-6666-0000-0000-000000000001', 'Ctx-2');
select pg_temp.ok((select request_id = 'sb-777' from audit.log where table_name = 'markets' and new_row ->> 'name' = 'Ctx-2'), 'sb-request-id is the fallback request id');

select set_config('request.headers', '{"x-request-id":"' || repeat('x', 500) || '"}', true);
insert into public.markets (client_id, name) values ('aaaaaaaa-6666-0000-0000-000000000001', 'Ctx-3');
select pg_temp.ok((select length(request_id) = 200 from audit.log where table_name = 'markets' and new_row ->> 'name' = 'Ctx-3'), 'a huge request-id header is cut to 200 characters');

select set_config('request.headers', '{not json', true);
insert into public.markets (client_id, name) values ('aaaaaaaa-6666-0000-0000-000000000001', 'Ctx-4');
select pg_temp.ok((select request_id is null from audit.log where table_name = 'markets' and new_row ->> 'name' = 'Ctx-4'), 'unreadable header JSON never breaks the business write (request id is NULL)');

select set_config('request.headers', '', true);
select set_config('request.jwt.claims', '', true);
insert into public.markets (client_id, name) values ('aaaaaaaa-6666-0000-0000-000000000001', 'Ctx-5');
select pg_temp.ok((select actor is null and jwt_role is null and effective_role is null and request_id is null and session_role = session_user
                   from audit.log where table_name = 'markets' and new_row ->> 'name' = 'Ctx-5'), 'a change made directly in SQL has no user, JWT or request, but still names the connected role');

set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
insert into public.clients (name) values ('Audit Client Svc');
reset role;
select pg_temp.ok((select actor is null and jwt_role = 'service_role' and effective_role = 'service_role'
                   from audit.log where table_name = 'clients' and new_row ->> 'name' = 'Audit Client Svc'), 'a service_role change is labelled service_role');
select set_config('request.jwt.claims', '', true);

-- ------------------------------------------------------------ B. monthly partitions
select pg_temp.ok((select bool_and(tableoid::regclass::text = 'audit.log_' || to_char(at at time zone 'UTC', 'YYYY_MM')) from audit.log),
                  'every row sits in the partition of its UTC month');
select pg_temp.ok((select count(*) from audit.partition_health where default_rows = 0 and monthly_partitions >= 4) = 1, 'partition_health: nothing in the default partition, at least 4 months covered');

-- ------------------------------------------------------------ C. append-only
select set_config('test.cur', 'audit.log_' || to_char(now() at time zone 'UTC', 'YYYY_MM'), true);
set local role service_role;
select pg_temp.ok((select count(*) from audit.log) > 0, 'service_role can read the log');
select pg_temp.expect($$update audit.log set op = op$$, '42501', 'service_role cannot UPDATE the log');
select pg_temp.expect($$delete from audit.log$$, '42501', 'service_role cannot DELETE from the log');
select pg_temp.expect($$truncate audit.log$$, '42501', 'service_role cannot TRUNCATE the log');
select pg_temp.expect(format('truncate %s', current_setting('test.cur')), '42501', 'service_role cannot TRUNCATE a partition');
select pg_temp.expect(format('delete from %s', current_setting('test.cur')), '42501', 'service_role cannot DELETE from a partition');
select pg_temp.expect($$insert into audit.log (table_name, op) values ('clients', 'INSERT')$$, '42501', 'service_role cannot write a log row of its own');
select pg_temp.expect(format('drop table %s', current_setting('test.cur')), '42501', 'service_role cannot drop a partition');
select pg_temp.expect($$alter table audit.log disable trigger all$$, '42501', 'service_role cannot switch the triggers off');
select pg_temp.expect($$select audit.ensure_partitions()$$, '42501', 'service_role cannot run the partition job');
select pg_temp.expect($$select audit.drop_old_partitions(24)$$, '42501', 'service_role cannot run retention');
reset role;
set local role authenticated;
select pg_temp.expect($$select * from audit.log$$, '42501', 'authenticated cannot read the log');
select pg_temp.expect($$select * from audit.retention_log$$, '42501', 'authenticated cannot read the retention log');
select pg_temp.expect($$select * from audit.partition_health$$, '42501', 'authenticated cannot read partition health');
select pg_temp.expect($$insert into audit.log (table_name, op) values ('clients', 'INSERT')$$, '42501', 'authenticated cannot forge a log row');
reset role;
set local role anon;
select pg_temp.expect($$select * from audit.log$$, '42501', 'anon cannot read the log');
reset role;

-- the owner is blocked by the triggers
select pg_temp.expect_msg($$update audit.log set op = op$$, '%append-only%', 'the owner cannot UPDATE the log (trigger)');
select pg_temp.expect_msg($$delete from audit.log$$, '%append-only%', 'the owner cannot DELETE from the log (trigger)');
select pg_temp.expect_msg($$truncate audit.log$$, '%append-only%', 'the owner cannot TRUNCATE the log (trigger)');
select pg_temp.expect_msg(format('update %s set op = op', current_setting('test.cur')), '%append-only%', 'the owner cannot UPDATE a partition directly');
select pg_temp.expect_msg(format('delete from %s', current_setting('test.cur')), '%append-only%', 'the owner cannot DELETE from a partition directly');
select pg_temp.expect_msg(format('truncate %s', current_setting('test.cur')), '%append-only%', 'the owner cannot TRUNCATE a partition directly (its own trigger)');
select pg_temp.expect_msg($$truncate audit.log_default$$, '%append-only%', 'the owner cannot TRUNCATE the default partition');
select pg_temp.expect_msg($$truncate audit.log cascade$$, '%append-only%', 'TRUNCATE ... CASCADE is blocked too');
select pg_temp.expect_msg($$truncate audit.retention_log$$, '%append-only%', 'the retention log cannot be truncated');

-- privileges widened by mistake: the triggers still hold
grant update, delete, truncate on audit.log to service_role;
select pg_temp.run(format('grant update, delete, truncate on %s to service_role', current_setting('test.cur')));
set local role service_role;
select pg_temp.expect_msg($$update audit.log set op = op$$, '%append-only%', 'even with UPDATE granted by mistake, service_role is stopped by the trigger');
select pg_temp.expect_msg($$delete from audit.log$$, '%append-only%', 'even with DELETE granted by mistake, service_role is stopped by the trigger');
select pg_temp.expect_msg($$truncate audit.log$$, '%append-only%', 'even with TRUNCATE granted by mistake, service_role is stopped by the trigger');
select pg_temp.expect_msg(format('truncate %s', current_setting('test.cur')), '%append-only%', 'and on the partition itself');
reset role;

-- ------------------------------------------------------------ D. partition lifecycle
select pg_temp.ok(audit.ensure_partitions() = 0, 'ensure_partitions is idempotent: nothing to create');
select pg_temp.ok(audit.ensure_partitions(audit.utc_month(), (audit.utc_month() + interval '6 months')::date) = 3, 'asking for 6 months ahead creates the 3 missing ones');
select pg_temp.ok(audit.ensure_partitions(audit.utc_month(), (audit.utc_month() + interval '6 months')::date) = 0, 'and a second call creates none');

-- rows that have no partition go to the default partition instead of failing the write
insert into audit.log (at, table_name, op, row_id) values
  ('2031-03-15 10:00+00', 'clients', 'INSERT', 'stranded-1'),
  ('2031-03-20 10:00+00', 'clients', 'INSERT', 'stranded-2'),
  ('2033-07-02 10:00+00', 'clients', 'INSERT', 'stranded-3');
select set_config('test.ids', (select array_agg(id order by id)::text from audit.log where row_id like 'stranded-%'), true);
select pg_temp.ok((select default_rows from audit.partition_health) = 3, 'rows with no partition sit in the default partition and partition_health shows 3');
select pg_temp.ok(audit.ensure_partitions('2031-03-01', '2031-03-01') = 1, 'ensure_partitions for that month repairs the default partition');
select pg_temp.ok((select default_rows from audit.partition_health) = 0, 'the default partition is empty again');
select pg_temp.ok((select array_agg(id order by id)::text from audit.log where row_id like 'stranded-%') = current_setting('test.ids'), 'no row lost, same ids');
select pg_temp.ok((select array_agg(tableoid::regclass::text order by row_id) from audit.log where row_id like 'stranded-%') = array['audit.log_2031_03', 'audit.log_2031_03', 'audit.log_2033_07'],
                  'each row is in the partition of its month (the 2033 one too: the repair covers every stranded month)');
select pg_temp.ok((select relrowsecurity from pg_class where oid = 'audit.log_2031_03'::regclass)
              and (select relrowsecurity from pg_class where oid = 'audit.log_default'::regclass), 'new partitions and the new default have RLS on');
select pg_temp.ok(not has_table_privilege('service_role', 'audit.log_2031_03', 'select') and not has_table_privilege('authenticated', 'audit.log_2031_03', 'select'), 'new partitions grant nothing to the API roles');
select pg_temp.expect_msg($$truncate audit.log_2031_03$$, '%append-only%', 'a new partition is protected against TRUNCATE');
select pg_temp.expect_msg($$truncate audit.log_default$$, '%append-only%', 'the re-created default partition is protected against TRUNCATE');
select pg_temp.expect_msg($$delete from audit.log_2031_03$$, '%append-only%', 'a new partition is protected against DELETE (cloned row trigger)');

-- retention
select pg_temp.ok(audit.ensure_partitions('2020-01-01', '2020-02-01') = 2, 'two old partitions created for the retention test');
insert into audit.log (at, table_name, op, row_id) values
  ('2020-01-10 10:00+00', 'clients', 'INSERT', 'old-1'), ('2020-01-11 10:00+00', 'clients', 'INSERT', 'old-2'), ('2020-02-03 10:00+00', 'clients', 'INSERT', 'old-3');
select set_config('test.recent', (select count(*) from audit.log where at >= '2026-01-01+00')::text, true);
select pg_temp.expect($$select audit.drop_old_partitions(6)$$, 'P0001', 'retention refuses to keep fewer than 12 months');
select pg_temp.expect($$select audit.drop_old_partitions(null)$$, 'P0001', 'retention refuses a NULL');
select pg_temp.ok(audit.drop_old_partitions(24) = 2, 'retention (24 months) drops the two old partitions');
select pg_temp.ok(to_regclass('audit.log_2020_01') is null and to_regclass('audit.log_2020_02') is null, 'the old partitions are gone');
select pg_temp.ok((select count(*) from audit.log where at >= '2026-01-01+00')::text = current_setting('test.recent'), 'recent history is untouched');
select pg_temp.ok((select array_agg(partition_name || ':' || rows_dropped order by partition_name) from audit.retention_log) = array['log_2020_01:2', 'log_2020_02:1'],
                  'the retention log says what was dropped and how many rows it held');
select pg_temp.ok(audit.drop_old_partitions(24) = 0, 'a second run drops nothing');
select pg_temp.expect_msg($$update audit.retention_log set rows_dropped = 0$$, '%append-only%', 'the retention log cannot be edited');
select pg_temp.expect_msg($$delete from audit.retention_log$$, '%append-only%', 'the retention log cannot be deleted from');

-- ------------------------------------------------------------ E. scheduling (against a stub of pg_cron, not the real one)
select pg_temp.ok(audit.schedule_maintenance() is false, 'without pg_cron, schedule_maintenance says so and returns false');
create schema cron;
create table cron.calls (jobname text, schedule text, command text);
create function cron.schedule(p_job text, p_schedule text, p_command text) returns bigint language sql as $f$
  insert into cron.calls values (p_job, p_schedule, p_command) returning 1::bigint $f$;
select pg_temp.ok(audit.schedule_maintenance() is true, 'with pg_cron present, schedule_maintenance returns true');
select pg_temp.ok((select array_agg(command) from cron.calls) = array['select audit.ensure_partitions()'], 'by default it schedules only the harmless partition job, NOT the retention that deletes history');
delete from cron.calls;
select pg_temp.ok(audit.schedule_maintenance(24) is true, 'scheduling with a keep period returns true');
select pg_temp.ok((select array_agg(command order by jobname) from cron.calls) = array['select audit.drop_old_partitions(24)', 'select audit.ensure_partitions()'], 'retention is scheduled only when asked for, with the keep period given');
select pg_temp.expect($$select audit.schedule_maintenance(6)$$, 'P0001', 'and scheduling retention below 12 months is refused');
rollback;
