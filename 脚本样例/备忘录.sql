/*
 DACS账号密码
 yangzhi_apex
 4yy8t.rJ93HE
 
 1、2025.12.1李润物调整过日志打印，生产需更新log4j2-prod.xml(测试是log4j2-dev.xml)【刘江】
 2、2025.12.2客户需要提供平台操作文档，和系统培训客户方成员便于后期运维（任务开发，数据排查）【 刘江 】
 3、2025.12.4记录问题：当主数据编码发生变更时，会将编码同步变更到融合表，但是不会变更交易代码。
 影响：行情表中的交易代码没变更，行情表模型设计了TRD_CODE，业务经常直接使用，导致数据少了(实际未少)
 例如融资融券明细，业务直接使用trd_code，920725只有今年8月之后的行情，
 源头上有8月之前的，融合数据的SECU_ID发生了变更，但是未同步变更trd_code导致【待议】
 4、增加针对调度的统计和监控-运营大屏【已完成-林波涛】
 5、万得表直接变更业务主键字段，导致多源融合的资讯清洗融合数据产生冗余数据【万得问题-可忽略】
 6、清洗融合任务失败时的邮件预警机制【待处理-林波涛】
 7、融合血缘关系没有被记录【待处理-李润物】
 8、针对万得业务主键字段值直接变更导致产生脏数据的表，清洗任务改用object_id做清洗，改唯一索引为普通索引，融合需加新逻辑或者板块处理【待处理-刘江】
 9、日志删除任务是否考虑调整调度为顺序调度或者调度模式可选，当前为周期调度，考虑到后续需要任务越来越多【待确认】
 10、部分万得表在S_INFO_WINDCODE临时代码变更为正式代码时，变更时间与WINDCUSTOMCODE的变更时间过于接近，
 导致清洗时关联不到，考虑将清洗时的推移天数单位改为小时/分钟，且清洗任务source表的推移时间无法配置【待处理-林波涛】
 11、离线清洗增量回撤时间单位调整为分钟【待处理-刘波】
 12、主数据编码变更，中间表和融合表传参反了【待处理-刘波】
 13、清洗融合任务失败时的预警机制日志/数据库 
 14、主数据证券模型针对全称、简称、上市日期等非主数据模型表获取的字段西悉尼进行对应证券类型的指定表的映射字段监控同步【 待处理 - 林波涛 】
 
 
 
 
 1 、清洗顺序调度    启动数量 / 总数
 2 、清洗周期调度    启动数量 / 总数
 3 、清洗依赖调度    启动数量 / 总数
 4 、融合顺序调度    启动数量 / 总数
 
 
 邮件格式
 任务类型-任务名称 时间
 
 优先级 4、6、10 11
 
 
 
 2025.12.16调整10.68.133.39的nginx配置与生产保持一致，观察flink集群转发的日志多久失效
 2025.12.25调整10.68.133.39的nginx的flink集群反向代理配置-----------------2026.1.6已验证生效待下次生产更新
 
 */
-------编码值查询----------------------
--最小公司编码
SELECT
    MAX(TO_NUMBER(COM_CODE))
FROM
    MAPPING_COMPANY
WHERE
    COM_CODE <> '999'
    AND TO_NUMBER(COM_CODE) <= 20000 --最小证券编码
SELECT
    MAX(
        TO_NUMBER(SUBSTR(SECU_CODE, INSTR(SECU_CODE, '.') + 1))
    )
FROM
    MAPPING_SECURITIES
WHERE
    TO_NUMBER(SUBSTR(SECU_CODE, INSTR(SECU_CODE, '.') + 1)) <= 20000 --公司查询
SELECT
    *
FROM
    MAPPING_COMPANY
WHERE
    COM_CODE = '530161'
    AND IS_VALID = 1
SELECT
    *
FROM
    MAPPING_COMPANY
WHERE
    '91110105348398953G' = UF_SC_CREDIT_CODE
    AND IS_VALID = 1
SELECT
    *
FROM
    MAPPING_COMPANY
WHERE
    '北京保联盈信息咨询服务有限责任公司' = COM_NAME
    AND IS_VALID = 1
UPDATE
    MAPPING_COMPANY
SET
    COM_CODE = '11582',
    UPD_TIME = SYSDATE
WHERE
    COM_CODE = '530161'
    AND RS_ID = 'JY'
    AND IS_VALID = 1 --证券查询
SELECT
    *
FROM
    MAPPING_SECURITIES
WHERE
    SECU_CODE IN ('I.286382')
    AND IS_VALID = 1
SELECT
    *
FROM
    MAPPING_SECURITIES
WHERE
    SECU_CODE_SOURCE IN ('XT.6194818')
    AND IS_VALID = 1
SELECT
    *
FROM
    MAPPING_SECURITIES
WHERE
    RECORD_ID = '1462144'
    AND IS_VALID = 1
SELECT
    *
FROM
    MAPPING_SECURITIES
WHERE
    IS_VALID = 1
    AND TRD_CODE = '145905'
    AND EXCHANGE_CODE = 'CZCE'
    AND TYP_CODE like 'FUND%'
    AND RS_ID <> 'CH'
SELECT
    *
FROM
    MAPPING_SECURITIES
WHERE
    IS_VALID = 1
    AND UPPER(TRD_CODE) IN('CN6015')
    AND SECU_CODE LIKE 'FU.%'
UPDATE
    MAPPING_SECURITIE
SET
    SECU_CODE = 'I.10823',
    UPD_TIME = SYSDATE
WHERE
    IS_VALID = 1
    AND RS_ID = 'CH'
    AND SECU_CODE = 'I.286382' TQ_IX_BASICINFO.CREATINDEXORGCODE通过SECODE关联TQ_OA_SECURITYMAP 80002557 中央国债登记结算有限责任公司 一个secode对应多个mapcode对应有财富 、 全价 、 净价三种 （ MAPTYPE分别为80 ， 81 ， 82 ） ， 取三条 80068776 恒生指数有限公司 通过限制TQ_OA_SECURITYMAP.MAPTYPE = 72 （ 指数上市代码 ） 取唯一披露 10000018 中信证券股份有限公司 通过限制TQ_OA_SECURITYMAP.MAPTYPE = 72 （ 指数上市代码 ） 取唯一披露 80058815 标准普尔评估有限公司 通过限制TQ_OA_SECURITYMAP.MAPTYPE = 72 （ 指数上市代码 ） 取唯一披露 SECODE IN (
        SELECT
            SECODE
        FROM
            FC_FINDB.TQ_IX_BASICINFO
        WHERE
            ISVALID = 1
            AND CREATINDEXORGCODE = '80002557'
    ) --80002557	中央国债登记结算有限责任公司
SELECT
    B.MAPCODE,
    B.MAPNAME,
    B.MAPTYPE,
    A.SYMBOL,
    A.INDEXNAME,
    A.*
FROM
    FC_FINDB.TQ_IX_BASICINFO A
    JOIN FC_FINDB.TQ_OA_SECURITYMAP B ON A.SECODE = B.SECODE
    AND B.ISVALID = 1
    AND B.MAPTYPE IN ('80', '81', '82')
WHERE
    A.CREATINDEXORGCODE = '80002557' --80068776	恒生指数有限公司
SELECT
    B.MAPCODE,
    B.MAPNAME,
    B.MAPTYPE,
    A.SYMBOL,
    A.INDEXNAME,
    A.*
FROM
    FC_FINDB.TQ_IX_BASICINFO A
    JOIN FC_FINDB.TQ_OA_SECURITYMAP B ON A.SECODE = B.SECODE
    AND B.ISVALID = 1
    AND B.MAPTYPE = '72'
WHERE
    A.CREATINDEXORGCODE = '80068776' --10000018	中信证券股份有限公司
SELECT
    B.MAPCODE,
    B.MAPNAME,
    B.MAPTYPE,
    A.SYMBOL,
    A.INDEXNAME,
    A.*
FROM
    FC_FINDB.TQ_IX_BASICINFO A
    JOIN FC_FINDB.TQ_OA_SECURITYMAP B ON A.SECODE = B.SECODE
    AND B.ISVALID = 1
    AND B.MAPTYPE = '72'
WHERE
    A.CREATINDEXORGCODE = '10000018' --80058815	标准普尔评估有限公司
SELECT
    B.MAPCODE,
    B.MAPNAME,
    B.MAPTYPE,
    A.SYMBOL,
    A.INDEXNAME,
    A.*
FROM
    FC_FINDB.TQ_IX_BASICINFO A
    JOIN FC_FINDB.TQ_OA_SECURITYMAP B ON A.SECODE = B.SECODE
    AND B.ISVALID = 1
    AND B.MAPTYPE = '72'
WHERE
    A.CREATINDEXORGCODE = '80058815'