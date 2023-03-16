/* Create table used to store Top SQL snapshots.
   Can be in any database, will require very little storage */
declare @curr_dat datetime;
SET @curr_dat = getdate();
SELECT @curr_dat AS date_time, max(plan_generation_num) as max_plan_generation_num, sql_handle, plan_handle, sum(execution_count) as execution_count,
  sum(total_worker_time) as total_worker_time, sum(total_physical_reads) as total_physical_reads,
  sum(total_logical_writes) as total_logical_writes, sum(total_logical_reads) as total_logical_reads, sum(total_clr_time) as total_clr_time,
  sum(total_elapsed_time) as total_elapsed_time, sum(total_rows) as total_rows, sum(total_dop) as total_dop
INTO newrelic_exec_query_stats FROM sys.dm_exec_query_stats GROUP BY sql_handle, plan_handle;
go


CREATE OR ALTER PROC NewRelic_Top_SQL @seconds INT, @num_sql INT
AS
/* Stored procedure to grab top SQL snapshots and do
   a diff from previous snapshot. Takes two parameters
   @seconds - the time between snapshots.
   @num_sql - the number of top SQL statements to be returned. */
/* Switch row count off and get the current time. */
SET NOCOUNT ON;
declare @curr_dat datetime;
SET @curr_dat = getdate();

/* Grab the top SQL statements in a temporary table.
  We will use the plan_handle and sql_handle. */
SELECT max(plan_generation_num) as max_plan_generation_num, sql_handle, plan_handle,
  sum(execution_count) as execution_count,
  sum(total_worker_time) as total_worker_time, sum(total_physical_reads) as total_physical_reads,
  sum(total_logical_writes) as total_logical_writes, sum(total_logical_reads) as total_logical_reads,
  sum(total_clr_time) as total_clr_time, sum(total_elapsed_time) as total_elapsed_time,
  sum(total_rows) as total_rows, sum(total_dop) as total_dop
INTO #temp_exec_query_stats
FROM sys.dm_exec_query_stats WITH (NOLOCK)
GROUP BY sql_handle, plan_handle;

/* Get the time from the previous snapshot stored in the permanent table. */
declare @last_dat datetime;
SELECT @last_dat = max(date_time) FROM newrelic_exec_query_stats;
/* Only return data if we are relatively close to the previous snapshot. */
IF @last_dat IS NOT NULL AND datediff(second, @last_dat, @curr_dat) < @seconds*1.5
BEGIN
  /* Now do a diff to get the top SQL and store the in another temporary table for now. */
  SELECT curr.max_plan_generation_num, curr.sql_handle, curr.plan_handle, curr.execution_count - last.execution_count as execution_count,
    curr.total_worker_time - last.total_worker_time as worker_time, curr.total_physical_reads - last.total_physical_reads as physical_reads,
    curr.total_logical_writes - last.total_logical_writes as logical_writes, curr.total_logical_reads - last.total_logical_reads as logical_reads,
    curr.total_clr_time - last.total_clr_time as clr_time, curr.total_elapsed_time - last.total_elapsed_time as elapsed_time,
    curr.total_rows - last.total_rows as rows, curr.total_dop - last.total_dop as degree_parallel
  INTO #temp_rtn_query_stats
  FROM #temp_exec_query_stats curr, newrelic_exec_query_stats last
  WHERE curr.sql_handle = last.sql_handle
  AND curr.plan_handle = last.plan_handle;

  /* Now we need to add any new statements we missed with the inner join (could probably have done an outer join?). */
  INSERT INTO #temp_rtn_query_stats
  SELECT curr.max_plan_generation_num, curr.sql_handle, curr.plan_handle, curr.execution_count, curr.total_worker_time,
    curr.total_physical_reads, curr.total_logical_writes, curr.total_logical_reads, curr.total_clr_time,
    curr.total_elapsed_time, curr.total_rows, curr.total_dop
  FROM #temp_exec_query_stats curr
  WHERE NOT EXISTS (SELECT last.sql_handle
    FROM newrelic_exec_query_stats last
    WHERE curr.plan_handle = last.plan_handle
    AND curr.sql_handle = last.sql_handle);

  /* New Relic requires a row count, so switch this back on. */
  SET NOCOUNT OFF;
  /* Now return the top SQL to New Relic. Top SQL by total elapsed time.
    We need the plan_handle to get the database name. We send the sql_handle
    to New Relic, as this is consistent across instance restarts */
  SELECT TOP (@num_sql)
    @@SERVERNAME AS sql_hostname, ISNULL(DB_NAME(qt.dbid),'') as database_name,
    LEFT(qt.[text], 50) as short_text, CAST(qp.query_plan AS VARCHAR(MAX)) as query_plan,
    tmp.sql_handle, tmp.max_plan_generation_num, tmp.execution_count, tmp.worker_time/1000 as worker_time_ms,
    tmp.physical_reads, tmp.logical_writes, tmp.logical_reads, tmp.clr_time/1000 as clr_time_ms,
    tmp.elapsed_time/1000 as elapsed_time_ms, tmp.rows, tmp.degree_parallel, qt.text as complete_text
  FROM #temp_rtn_query_stats tmp
  CROSS APPLY sys.dm_exec_sql_text(tmp.plan_handle) as qt
  CROSS APPLY sys.dm_exec_text_query_plan(tmp.plan_handle, 0, -1) as qp
  WHERE tmp.execution_count > 0
  ORDER BY tmp.elapsed_time DESC;
  /* Set the row count off again. */
  SET NOCOUNT ON;
END;
/* Delete all rows from the previous snapshot, we have finished with this now. */
truncate table newrelic_exec_query_stats;
/* Save the current snapshot for the next time and drop the temporary tables. */
INSERT INTO newrelic_exec_query_stats
SELECT @curr_dat AS date_time, max_plan_generation_num, sql_handle, plan_handle, execution_count,
  total_worker_time, total_physical_reads, total_logical_writes, total_logical_reads, total_clr_time,
  total_elapsed_time, total_rows, total_dop
FROM #temp_exec_query_stats;
go
/* Grant execute permission to the New Relic user. 
grant execute on NewRelic_Top_SQL to newrelic
go */
