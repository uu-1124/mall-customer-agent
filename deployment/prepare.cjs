const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto');
const {hashSync}=require('bcryptjs');
const out=__dirname;
const yaml={stringify:value=>JSON.stringify(value,null,2)+'\n'};
const secretPath=path.join(out,'secrets.json');
const random=()=>crypto.randomBytes(24).toString('hex');
const secrets=fs.existsSync(secretPath)?JSON.parse(fs.readFileSync(secretPath)): {mysql:random(),redis:random(),rabbit:random(),minio:random(),jwt:random(),nacos:crypto.randomBytes(48).toString('base64'),monitor:random(),demoPassword:random()};
secrets.mysqlRoot ||= random();
secrets.nacosIdentity ||= random();
secrets.demoPassword ||= random();
for(const dir of ['config','init','jars','web/admin','web/shop','web/demo-assets'])fs.mkdirSync(path.join(out,dir),{recursive:true});
if(Buffer.byteLength(secrets.demoPassword,'utf8')>72)throw new Error('The development demo password must be at most 72 UTF-8 bytes.');
fs.writeFileSync(secretPath,JSON.stringify(secrets,null,2),{mode:0o600});
const write=(name,data)=>fs.writeFileSync(path.join(out,name),data);
const mirror='docker.m.daocloud.io/';
const services={
 mysql:{image:mirror+'library/mysql:8.0.35',restart:'unless-stopped',environment:{MYSQL_DATABASE:'mall',MYSQL_USER:'mall',MYSQL_PASSWORD:secrets.mysql,MYSQL_ROOT_PASSWORD:secrets.mysqlRoot,TZ:'Asia/Shanghai'},command:['--character-set-server=utf8mb4','--collation-server=utf8mb4_unicode_ci'],volumes:['mysql-data:/var/lib/mysql','./init:/docker-entrypoint-initdb.d:ro'],healthcheck:{test:['CMD-SHELL','MYSQL_PWD=$$MYSQL_ROOT_PASSWORD mysql -uroot -Nse "SELECT 1" >/dev/null'],interval:'10s',timeout:'5s',retries:30},mem_limit:'1500m'},
 redis:{image:mirror+'library/redis:7.4-alpine',restart:'unless-stopped',command:['redis-server','--appendonly','yes','--requirepass',secrets.redis],volumes:['redis-data:/data'],healthcheck:{test:['CMD','redis-cli','-a',secrets.redis,'ping'],interval:'10s',timeout:'5s',retries:20},mem_limit:'256m'},
 mongo:{image:mirror+'library/mongo:7.0',restart:'unless-stopped',volumes:['mongo-data:/data/db'],mem_limit:'768m'},
 rabbitmq:{image:mirror+'library/rabbitmq:3.13-management-alpine',restart:'unless-stopped',environment:{RABBITMQ_DEFAULT_USER:'mall',RABBITMQ_DEFAULT_PASS:secrets.rabbit,RABBITMQ_DEFAULT_VHOST:'/mall'},volumes:['rabbit-data:/var/lib/rabbitmq'],healthcheck:{test:['CMD','rabbitmq-diagnostics','-q','ping'],interval:'15s',timeout:'10s',retries:30},mem_limit:'768m'},
 nacos:{image:mirror+'nacos/nacos-server:v2.5.1',restart:'unless-stopped',environment:{MODE:'standalone',PREFER_HOST_MODE:'hostname',NACOS_AUTH_ENABLE:'false',NACOS_AUTH_TOKEN:secrets.nacos,NACOS_AUTH_IDENTITY_KEY:'mallserver',NACOS_AUTH_IDENTITY_VALUE:secrets.nacosIdentity,JVM_XMS:'256m',JVM_XMX:'512m',JVM_XMN:'128m'},volumes:['nacos-data:/home/nacos/data'],healthcheck:{test:['CMD-SHELL','curl -fsS http://localhost:8848/nacos/v1/console/health/readiness'],interval:'10s',timeout:'5s',retries:45},mem_limit:'1g'},
 elasticsearch:{image:mirror+'library/elasticsearch:8.18.0',restart:'unless-stopped',environment:{'discovery.type':'single-node','xpack.security.enabled':'false','xpack.security.enrollment.enabled':'false',ES_JAVA_OPTS:'-Xms512m -Xmx512m'},volumes:['es-data:/usr/share/elasticsearch/data','./es-ik:/usr/share/elasticsearch/plugins/ik:ro'],healthcheck:{test:['CMD-SHELL','curl -fsS http://localhost:9200/_cluster/health'],interval:'10s',timeout:'5s',retries:45},mem_limit:'1800m'},
 minio:{image:'mall-swarm/minio:RELEASE.2025-07-23T15-54-02Z',build:{context:'./minio-runtime'},restart:'unless-stopped',command:['server','/data','--console-address',':9001'],environment:{MINIO_ROOT_USER:'mallminio',MINIO_ROOT_PASSWORD:secrets.minio},ports:['127.0.0.1:9000:9000','127.0.0.1:9001:9001'],volumes:['minio-data:/data'],mem_limit:'512m'}
};
write('compose.yaml',yaml.stringify({name:'mall-swarm',services,volumes:Object.fromEntries(['mysql','redis','mongo','rabbit','nacos','es','minio'].map(x=>[x+'-data',{}]))}));
const hash=hashSync(secrets.demoPassword,12);
write('init/02-demo-accounts.sql',`-- Local development only: generated alongside the ignored secrets.json.
INSERT INTO ums_admin (username,password,nick_name,create_time,status)
SELECT 'admin','${hash}','演示管理员',NOW(),1
WHERE NOT EXISTS (SELECT 1 FROM ums_admin WHERE username='admin');
UPDATE ums_admin SET password='${hash}' WHERE username='admin';
INSERT INTO ums_admin_role_relation (admin_id,role_id)
SELECT a.id,r.id FROM ums_admin a JOIN ums_role r ON r.id=5
WHERE a.username='admin' AND NOT EXISTS (
  SELECT 1 FROM ums_admin_role_relation ar WHERE ar.admin_id=a.id AND ar.role_id=r.id
);
INSERT INTO ums_member (member_level_id,username,password,nickname,status,create_time,integration,growth)
SELECT 1,'member','${hash}','演示买家',1,NOW(),10000,10000
WHERE NOT EXISTS (SELECT 1 FROM ums_member WHERE username='member');
UPDATE ums_member SET password='${hash}' WHERE username='member';
INSERT INTO ums_member_receive_address
  (member_id,name,phone_number,default_status,province,city,region,detail_address)
SELECT m.id,'演示收件人','00000000000',1,'北京市','北京市','朝阳区','演示地址（不可投递）'
FROM ums_member m WHERE m.username='member' AND NOT EXISTS (
  SELECT 1 FROM ums_member_receive_address a WHERE a.member_id=m.id
);
INSERT INTO oms_company_address
  (address_name,send_status,receive_status,name,phone,province,city,region,detail_address)
SELECT '演示仓库',1,1,'演示仓库','00000000001','北京市','北京市','朝阳区','演示仓库（不可投递）'
WHERE NOT EXISTS (SELECT 1 FROM oms_company_address WHERE address_name='演示仓库');
`);
console.log('Deployment configuration generated; credentials saved locally.');

require('./prepare-local.cjs');
