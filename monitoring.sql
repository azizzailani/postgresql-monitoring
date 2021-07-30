--Impor dump ke database yang ada
psql -d newdb -f dump.sql

--Dump database pada remote host ke file
$ pg_dump -U username -h hostname databasename > dump.sql

-- Buang keluaran kueri ke CSV
\copy (YOUR_SQL_QUERY) to ~/Downloads/my.csv with csv;

-- semua tabel dan ukurannya, dengan/tanpa indeks
select datname, pg_size_pretty(pg_database_size(datname))
from pg_database
order by pg_database_size(datname) desc;

--Lihat jumlah koneksi maksimal yang didukung server
SHOW max_connections;

/* total koneksi digunakan */
SELECT COUNT(*) FROM 
pg_stat_activity;

--psql_oldest_query
SELECT application_name, 
       pid, 
       state,
       age(clock_timestamp(), query_start), /* How long has the query has been running in h:m:s */
       usename, 
       query /* The query text */
FROM pg_stat_activity
WHERE state != 'idle'
AND query NOT ILIKE '%pg_stat_activity%'
ORDER BY query_start asc;

--how_many_running_longer
SELECT count(*) 
FROM pg_stat_activity 
WHERE state != 'idle' 
AND query_start < (NOW() - INTERVAL '60 seconds');

/*
  Kill long-running read-only queries
*/
SELECT 
  application_name, 
  pg_cancel_backend(pid), /* returns boolean indicating whether or not query was killed */
  state, 
  age(clock_timestamp(), query_start), 
  usename, 
  query
FROM pg_stat_activity
WHERE state != 'idle' 
AND query ILIKE '%SELECT%' /* Safer to kill non-state-changing queries */
AND query_start < (NOW() - INTERVAL '300 seconds'); /* older than 5 minutes */

/* You can also kill the query if you have the pid */
SELECT pg_cancel_backend(12345);

--See the 10 slowest queries with over a 1000 calls
SELECT query, calls, (total_time/calls)::integer AS avg_time_ms 
FROM pg_stat_statements
WHERE calls > 1000
ORDER BY avg_time_ms DESC
LIMIT 10;

--See the 10 slowest SELECT queries with over a 1000 calls
SELECT query, calls, (total_time/calls)::integer AS avg_time_ms 
FROM pg_stat_statements
WHERE calls > 1000
AND query iLIKE '%SELECT%'
ORDER BY avg_time_ms DESC
LIMIT 10;

--See the 10 SELECT queries which touch the most number of rows.
--These queries may benefit from adding indexes to reduce the number
--of rows retrieved/affected.
SELECT
  rows, --rows is the number of rows retrieved/affected by the query
  query
FROM pg_stat_statements
WHERE query iLIKE '%SELECT%'
ORDER BY rows DESC
LIMIT 10;

SELECT 
  (heap_blks_hit::decimal / (heap_blks_hit + heap_blks_read)) as cache_hit_ratio
FROM 
  pg_statio_user_tables
WHERE relname = 'large_table';

--Rasio Hit Cache Keseluruhan Psql
SELECT 
  SUM(heap_blks_hit) / (SUM(heap_blks_hit) + SUM(heap_blks_read)) as cache_hit_ratio
FROM 
  pg_statio_user_tables;
  
--Tampilkan Buffer Bersama
SHOW SHARED_BUFFERS;

--indeks penggunaan rendah
WITH table_scans as (
    SELECT relid,
        tables.idx_scan + tables.seq_scan as all_scans,
        ( tables.n_tup_ins + tables.n_tup_upd + tables.n_tup_del ) as writes,
                pg_relation_size(relid) as table_size
        FROM pg_stat_user_tables as tables
),
all_writes as (
    SELECT sum(writes) as total_writes
    FROM table_scans
),
indexes as (
    SELECT idx_stat.relid, idx_stat.indexrelid,
        idx_stat.schemaname, idx_stat.relname as tablename,
        idx_stat.indexrelname as indexname,
        idx_stat.idx_scan,
        pg_relation_size(idx_stat.indexrelid) as index_bytes,
        indexdef ~* 'USING btree' AS idx_is_btree
    FROM pg_stat_user_indexes as idx_stat
        JOIN pg_index
            USING (indexrelid)
        JOIN pg_indexes as indexes
            ON idx_stat.schemaname = indexes.schemaname
                AND idx_stat.relname = indexes.tablename
                AND idx_stat.indexrelname = indexes.indexname
    WHERE pg_index.indisunique = FALSE
),
index_ratios AS (
SELECT schemaname, tablename, indexname,
    idx_scan, all_scans,
    round(( CASE WHEN all_scans = 0 THEN 0.0::NUMERIC
        ELSE idx_scan::NUMERIC/all_scans * 100 END),2) as index_scan_pct,
    writes,
    round((CASE WHEN writes = 0 THEN idx_scan::NUMERIC ELSE idx_scan::NUMERIC/writes END),2)
        as scans_per_write,
    pg_size_pretty(index_bytes) as index_size,
    pg_size_pretty(table_size) as table_size,
    idx_is_btree, index_bytes
    FROM indexes
    JOIN table_scans
    USING (relid)
),
index_groups AS (
SELECT 'Never Used Indexes' as reason, *, 1 as grp
FROM index_ratios
WHERE
    idx_scan = 0
    and idx_is_btree
UNION ALL
SELECT 'Low Scans, High Writes' as reason, *, 2 as grp
FROM index_ratios
WHERE
    scans_per_write <= 1
    and index_scan_pct < 10
    and idx_scan > 0
    and writes > 100
    and idx_is_btree
UNION ALL
SELECT 'Seldom Used Large Indexes' as reason, *, 3 as grp
FROM index_ratios
WHERE
    index_scan_pct < 5
    and scans_per_write > 1
    and idx_scan > 0
    and idx_is_btree
    and index_bytes > 100000000
UNION ALL
SELECT 'High-Write Large Non-Btree' as reason, index_ratios.*, 4 as grp 
FROM index_ratios, all_writes
WHERE
    ( writes::NUMERIC / ( total_writes + 1 ) ) > 0.02
    AND NOT idx_is_btree
    AND index_bytes > 100000000
ORDER BY grp, index_bytes DESC )
SELECT reason, schemaname, tablename, indexname,
    index_scan_pct, scans_per_write, index_size, table_size
FROM index_groups;

--Memblokir Kueri
SELECT blocked_activity.query    AS blocked_statement,
       blocking_activity.query   AS current_statement_in_blocking_process
 FROM  pg_catalog.pg_locks         blocked_locks
  JOIN pg_catalog.pg_stat_activity blocked_activity  ON blocked_activity.pid = blocked_locks.pid
  JOIN pg_catalog.pg_locks         blocking_locks 
      ON blocking_locks.locktype = blocked_locks.locktype
      AND blocking_locks.database IS NOT DISTINCT FROM blocked_locks.database
      AND blocking_locks.relation IS NOT DISTINCT FROM blocked_locks.relation
      AND blocking_locks.page IS NOT DISTINCT FROM blocked_locks.page
      AND blocking_locks.tuple IS NOT DISTINCT FROM blocked_locks.tuple
      AND blocking_locks.virtualxid IS NOT DISTINCT FROM blocked_locks.virtualxid
      AND blocking_locks.transactionid IS NOT DISTINCT FROM blocked_locks.transactionid
      AND blocking_locks.classid IS NOT DISTINCT FROM blocked_locks.classid
      AND blocking_locks.objid IS NOT DISTINCT FROM blocked_locks.objid
      AND blocking_locks.objsubid IS NOT DISTINCT FROM blocked_locks.objsubid
      AND blocking_locks.pid != blocked_locks.pid
  JOIN pg_catalog.pg_stat_activity blocking_activity ON blocking_activity.pid = blocking_locks.pid
 WHERE NOT blocked_locks.granted;
   
--  Lihat koneksi postgres
SELECT state, COUNT(*) FROM pg_stat_activity  
WHERE pid <> pg_backend_pid() 
GROUP BY 1;

SELECT application_name, COUNT(*) FROM pg_stat_activity  
WHERE pid <> pg_backend_pid() 
GROUP BY 1 ORDER BY 1;

SELECT count(*),client_addr FROM pg_stat_activity GROUP BY 2;

-- periksa status repliksi
-- pada master
select * from pg_stat_replication;

-- pada replika
select * from pg_stat_wal_receiver;

-- periksa delay replika
select now() - pg_last_xact_replay_timestamp() AS delay;