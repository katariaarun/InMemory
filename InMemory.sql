
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

