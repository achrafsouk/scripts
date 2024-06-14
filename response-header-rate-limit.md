# Rate liminting based on response headers

In this architecture, I describe how to rate limit requests processed by CloudFront / AWS WAF based on response headers sent by the origin.

## Step 1: Capture the header in CloudFront Functions

Implement a CloudFront Function on viewer response event of the cache behavior where you want to implement the rate limit. Make it as specific as possible to avoid unecessary costs.

The code of the function looks like this:

````
function handler(event) {
  var response = event.response;
  var ip = event.viewer.ip
  console.log(ip+ " " +response.headers['x-app'].value)
  delete response.headers['x-app']

  return response;
}
````

The function logs the IP and the application name of every request to CloudWatch Logs 

## Step 2: Capture the relevant log lines in ClouWatch logs

We are only interested in certain log lines in CloudWatch logs, for which we are creating a subscription filter to ship them to Kinesis Data Streams.

Example of logs in CloudWatch Logs:

````
2024-06-13T10:24:26.155Z	yiuMFE-C-zh-hC0pSP5R-O5BG3ap_Of6evMxor903iY6eZqmvDuAhA== START DistributionID: EM5IMR873FN1
2024-06-13T10:24:26.155Z	yiuMFE-C-zh-hC0pSP5R-O5BG3ap_Of6evMxor903iY6eZqmvDuAhA== 87.201.63.49 app35-15
2024-06-13T10:24:26.155Z	yiuMFE-C-zh-hC0pSP5R-O5BG3ap_Of6evMxor903iY6eZqmvDuAhA== END
2024-06-13T10:24:39.406Z	iZ5hVY4TdzAxYPM3O-Pm9M7QI_w2h_rMvGry9LsmlQM4MN3M4c8ufQ== START DistributionID: EM5IMR873FN1
2024-06-13T10:24:39.406Z	iZ5hVY4TdzAxYPM3O-Pm9M7QI_w2h_rMvGry9LsmlQM4MN3M4c8ufQ== 87.201.63.49 app35-15
2024-06-13T10:24:39.406Z	iZ5hVY4TdzAxYPM3O-Pm9M7QI_w2h_rMvGry9LsmlQM4MN3M4c8ufQ== END
2024-06-13T10:24:42.950Z	hfeaHApSKu1aNYvUgbh5_ocTx4TSEbii4uNWtr5b81Yehilq585kbQ== START DistributionID: EM5IMR873FN1
2024-06-13T10:24:42.950Z	hfeaHApSKu1aNYvUgbh5_ocTx4TSEbii4uNWtr5b81Yehilq585kbQ== 87.201.63.49 app35-15
2024-06-13T10:24:42.950Z	hfeaHApSKu1aNYvUgbh5_ocTx4TSEbii4uNWtr5b81Yehilq585kbQ== END
````

the subscription filter has the following path pattern:

````
[reqid, ip!=START && ip!=END, app]
````

Configure low retention time in the log group to avoid unecessary storage costs.

## Step 3: Process logs in Managed Apache Flink

Filter the top offeding IPs based on a moving window that is refreshed on a regular basis (e.g. 60 sec window refreshed every 1 sec). Then sink the IPs to a DynamoDB table, with a desired block TTL. 

I did not build this, but I used the Data analytics with Apache Flink feature in Kinsesis Data Stream to validate how it would work. It is based on a Zeppelin notebook with the following sequential tasks:

````
%flink.pyflink

import gzip
import base64

class preProcess(ScalarFunction):
    def eval(self, s):
        return str(gzip.decompress(s), 'utf-8')

st_env.register_function("preProcess", udf(preProcess(), DataTypes.BYTES(), DataTypes.STRING()))
````

````
%flink.ssql(type=update)

DROP TABLE IF EXISTS request_rates;
CREATE TABLE request_rates (
    data BYTES,
    proctime AS PROCTIME()
) WITH (
  'connector' = 'kinesis',
  'stream' = 'preply',
  'aws.region' = 'us-east-1',
  'scan.stream.initpos' = 'LATEST',
  'format' = 'raw'
);

````

````
%flink.ssql(type=update)

SELECT winend, ip, app_name, request_rate, app_rate_limit
FROM (
    SELECT  ip, SPLIT_INDEX(app,'-',0) AS app_name, CAST(SPLIT_INDEX(app,'-',1) AS INT) AS app_rate_limit, request_rate, winend
    FROM (
        SELECT  
            ip,
            app,
            COUNT(*) as request_rate,
            HOP_END(proctime, INTERVAL '1' SECOND, INTERVAL '60' SECOND) AS winend
        FROM (
            SELECT  
                JSON_VALUE(preProcess(data), '$.logEvents[0].extractedFields.app') as app, 
                JSON_VALUE(preProcess(data), '$.logEvents[0].extractedFields.ip') as ip,
                proctime
            FROM request_rates
        )
        GROUP BY 
            app, 
            ip,
            HOP(proctime, INTERVAL '1' SECOND, INTERVAL '60' SECOND)
    ) 
)
WHERE request_rate > app_rate_limit ;
````

## Step 4: Block offending IPs in AWS WAF.

In AWS WAF you have a static rule that blocks requests coming from any IP within an IP list. Run a Lambda function on with a regular frequency (e.g. 1 every 2 seconds), that queries the IPs in the DynamoDB table, and then update the IP list in AWS WAF.






