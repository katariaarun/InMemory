# InMemory
Automation &amp; Optimization of InMemory
This article covers in depth analysis to optimize use of InMemory in Oracle. 
With the latest Oracle releases it has given a significant performance boost with many features like InMemory. InMemory is basically an area in Memory (RAM) that is reserved for use to PERSISTENTLY store data from tables. The data in memory is pushed to InMemory manually and it remains there till we pull it from InMemory giving the developer/dba/Performance tuners a unique opportunity to select the data that they feel needs to be retrieved fast (rather than relying on Oracle engine to select data based on hotness like in case of buffer)
When we run a query the optimizer than looks for the data in InMemory, if its able to find the data in InMemory, it pulls the data from InMemory before looking for the data in disks. The IO operations hence are approximately ten times faster and data is retrieved in seconds as compared to minutes needed from disk.
However there are limitations and the limitation here is the size of inmemory that is there. If you have unlimited inmemory available then we can simply put all the tables into inmemory and the task of optimization is over.

But in real world scenario the Performance tuning team has a task at hand to optimally use the InMemory available and bring out the maximum benefit from the least amount of inmemory. 

Lets take an example, if a table has 100 columns and size of table is 7GB (after compression) and only 10 columns are being used in the reports, putting the whole table into InMemory would not make sense, it means we are using complete 7GB of InMemory. However we are actually using just 10 columns and rest 90 columns which are sitting in inmemory are actually wasting the space. The optimal way to use the InMemory would be to just put these 10 columns to inmemory and pull out rest 90 columns. The size used in memory now would be 0.7GB only. This way we are still getting the same benefit we were getting earlier but at a fraction of memory being used. 

Now that we have saved 90% of the space in InMemory, lets say there is another query that gets executed using 11th column, now this will not be served from InMemory only and the query wont perform well. Hence its a tuners job to constantly monitor the SQLs being directed to InMemory tables and constantly evolve the best set of columns that has to be put InMemory maximizing the benefits.

Automation:
Imagine doing this for all the queries that the frontend is issuing day in day out on hundreds of tables. This definitely needs some utility like the AWR etc. but there isnt one out yet from Oracle.
For this purpose i have designed a query that scans through the metadata from obiee queries that got executed in the past (using the usage tracking tables), scans through the tables being used, filtering out the columns being used in those queries. It then combines these findings to present a cumulative list of columns that need to be put inmemory that are being used in the reports. The utility further scans the InMemory area and fetches whats currently inmemory and also creates "alter table..." statements that can directly be used to put the corresponding columns into inmemory. All this can be done in minutes, constantly on a daily basis , ever evolving for all tables, for all columns.

Design:
The design is to complete the following steps some of them in order

1. Bring out all the tables (table_names) in your data schema and store in Tab_1
2. Bring out all the query string in your schema and store in Tab_2
3. Do a cross join on Tab_1 and Tab_2
4. From Tab_1 use the table names and substring out the table_name as well as the Alias that its using in the query Tab_2
	In the Oracle BI Application queries the usual syntax is TableName Alias /* */, hence we use the "/*" as the end point to do substring
5. Now we need to store the Table_name, Alias Name mapping in Tab_5
6. Join the result from point 5 to dba_tab_columns on table_name and build out the Alias_Name.column_name  data set
7. Now that we have the table which contains the AliasName.column_name we need to search for this fully qualified column name (AliasName.Column_name) in Tab_2 or the set of queries text we have
8. Filter out the table.column_names that are being used in the queries and store them seperately in Tab_8
9. Using list_agg function club the columns used in Queries and club the columns not used in queries.
10. Generate Alter table statements using the aggregated list of columns in point 9.



Query: 


/* Replace the <obiee_usage_tracking_schema> with the usage tracking schema name
   Replace the <Data Schema name> with Schema name where in the IM Tables are stored
   Replace the <Table Name> if you need to do this for a particular Table
   Replace the <path of particular Dashboard if needed> with dashboard path if you need to run this for a particular dashboard only>
*/

with s1 as 
(select /*+ parallel(32) */ * from 
(
    select  distinct  A.tablename, A.Column_name  from
    (select  trim(m.alias)||'.'||column_name FullColName, trim(m.tablename) Tablename, t.column_name from 
        (select distinct substr(str,1,instr(str,' ')) TableName, substr(str,instr(str,' T')+1) Alias 
            from ( select substr(str,0,instr(str,'/*')-1) str 
                from ( select dbms_lob.substr(a.query_blob,40,dbms_lob.instr(a.query_blob,b.Table_name||' ')) as str
                    from  (select s1.query_blob 
                            FROM <obiee_usage_tracking_schema>.s_nq_acct  s
                              inner join <obiee_usage_tracking_schema>.s_nq_db_acct s1
                              on s.id=s1.logical_query_id
                              where s.start_ts>sysdate-1
                              --and  s.saw_dashboard = '<path of particular dashboard if needed>'
                            ) A,
                            (select table_name from dba_tables where owner='<Data Schema Name>' and (
                            table_name LIKE '<TableName >' 
                            --or table_name like 'W_%_A' 
                            --or table_name like 'W_%_F' 
                            --or table_name like 'W_%_G' 
                            --or table_name like 'W_%_LKP'
                            )) B   -- x * y join for A n B
                       ) where str is not null
                ) where str is not null
        ) m  
        inner join dba_tab_columns t
        on t.TABLE_NAME=trim(m.tablename)
        where  owner='<Data Schema Name>'
    ) A ,
    (select /*+ materialize */ s1.query_blob
      FROM <obiee_usage_tracking_schema>.s_nq_acct  s
      inner join <obiee_usage_tracking_schema>.s_nq_db_acct s1
      on s.id=s1.logical_query_id
        where (s.saw_src_path, s.start_ts) in 
            ( select saw_src_path, max(start_ts) start_ts
                FROM <obiee_usage_tracking_schema>.s_nq_acct  s
                where s.start_ts>sysdate-2 /* filter to control how long to go back in time */
                --and s.saw_dashboard = '<path of particular dashboard if needed>'
                group by saw_src_path
            )
    ) B
        where dbms_lob.instr(B.query_blob,A.FullColName)>0
) A
    where A.tablename not in (select segment_name from gv$im_segments)
order by 1,2 )
select stmt || replace(trim(INMEM),' ',','||Chr(13))||' ) no inmemory ( '||Chr(13)|| replace(trim(NonINMEM),' ',','||Chr(13)) ||Chr(13)||' ); ' as FinalStmt from (
select 'alter table '||table_name||' inmemory memcompress for query high priority critical 
inmemory memcompress for query high ( '||Chr(13) STmt, listagg(IM||' ') within group(order by table_name) InMem, listagg(NonIM||' ') within group(order by table_name) NonInMem from (
select table_name, to_char(IM) IM, case when to_char(IM) is null then to_char(NonIM) else null end NonIM from (
select distinct t1.table_name, t1.column_name NonIM, s1.column_name IM from dba_Tab_columns t1 left outer join s1
on (t1.table_name=s1.tablename
and t1.column_name=s1.column_name)
where t1.table_name in (select tablename from s1)
order by 1,2,3
)
order by 1
) group by table_name
)









