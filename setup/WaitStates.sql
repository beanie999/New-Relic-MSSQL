/* Create table used to store wait state snapshots.
   Can be in any database, will require very little storage */
declare @curr_dat datetime;
SET @curr_dat = getdate();
SELECT @curr_dat AS date_time, wait_type, waiting_tasks_count, wait_time_ms, signal_wait_time_ms
INTO newrelic_os_wait_stats
FROM sys.dm_os_wait_stats;

CREATE OR ALTER PROC NewRelic_Wait_States @seconds INT
AS
/* Stored procedure to grab wait state snapshots and do
   a diff from previous snapshot. Takes one parameter
   (@seconds) the time between snapshots. */
/* Switch row count off and get the current time. */
SET NOCOUNT ON;
declare @curr_dat datetime;
SET @curr_dat = getdate();

/* Grab the current wait states in a temporary table. */
SELECT wait_type, waiting_tasks_count, wait_time_ms, signal_wait_time_ms
INTO #temp_os_wait_stats
FROM sys.dm_os_wait_stats WITH (NOLOCK);

/* Get the time from the previous snapshot stored in the permanent table. */
declare @last_dat datetime;
SELECT @last_dat = max(date_time) FROM newrelic_os_wait_stats;
/* Only return data if we are relatively close to the previous snapshot. */
IF @last_dat IS NOT NULL AND datediff(second, @last_dat, @curr_dat) < @seconds*1.5
BEGIN
  /* New Relic requires a row count, so switch this back on. */
  SET NOCOUNT OFF;
  /* Now return the diff to New Relic, do a WHERE check to ensure the values
    are positive (instance restart will give this). */
  SELECT 'WaitState' as customType, @@SERVERNAME AS sql_hostname, curr.wait_type,
    curr.waiting_tasks_count - last.waiting_tasks_count as waiting_tasks_count,
    curr.wait_time_ms - last.wait_time_ms as wait_time_ms,
    curr.signal_wait_time_ms - last.signal_wait_time_ms as signal_wait_time_ms
  FROM newrelic_os_wait_stats last, #temp_os_wait_stats curr
  WHERE last.wait_type = curr.wait_type
  AND curr.wait_time_ms > last.wait_time_ms;
  /* Set the row count off again. */
  SET NOCOUNT ON;
END;
/* Delete all rows from the previous snapshot, we have finished with this now. */
truncate table newrelic_os_wait_stats;
/* Save the current snapshot for the next time and drop the temporary table. */
INSERT INTO newrelic_os_wait_stats
SELECT @curr_dat AS date_time, wait_type, waiting_tasks_count, wait_time_ms, signal_wait_time_ms
FROM #temp_os_wait_stats;
drop table #temp_os_wait_stats;
go
/* Grant execute permission to the New Relic user. */
grant execute on NewRelic_Wait_States to newrelic;
go
