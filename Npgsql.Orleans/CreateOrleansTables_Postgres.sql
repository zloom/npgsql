/*
Implementation notes:

1) The general idea is that data is read and written through Orleans specific queries.
   Orleans operates on column names and types when reading and on parameter names and types when writing.
   
2) The implementations *must* preserve input and output names and types. Orleans uses these parameters to reads query results by name and type.
   Vendor and deployment specific tuning is allowed and contributions are encouraged as long as the interface contract
   is maintained.
	 
3) The implementation across vendor specific scripts *should* preserve the constraint names. This simplifies troubleshooting
   by virtue of uniform naming across concrete implementations.

5) ETag for Orleans is an opaque column that represents a unique version. The type of its actual implementation
   is not important as long as it represents a unique version. In this implementation we use INTs for versioning

6) For the sake of being explicit and removing ambiguity, Orleans expects some queries to return either TRUE as >0 value 
   or FALSE as =0 value. That is, affected rows or such does not matter. If an error is raised or an exception is thrown
   the query *must* ensure the entire transaction is rolled back and may either return FALSE or propagate the exception.
   Orleans handles exception as a failure and will retry.

7) The implementation follows the Extended Orleans membership protocol. For more information, see at:
		http://dotnet.github.io/orleans/Runtime-Implementation-Details/Runtime-Tables.html
		http://dotnet.github.io/orleans/Runtime-Implementation-Details/Cluster-Management
		https://github.com/dotnet/orleans/blob/master/src/Orleans/SystemTargetInterfaces/IMembershipTable.cs
*/




CREATE TABLE OrleansQuery
(
	QueryKey VARCHAR(64) NOT NULL,
	QueryText VARCHAR(8000) NOT NULL,

	CONSTRAINT OrleansQuery_Key PRIMARY KEY(QueryKey)
);

-- For each deployment, there will be only one (active) membership version table version column which will be updated periodically.
CREATE TABLE OrleansMembershipVersionTable
(
	DeploymentId VARCHAR(150) NOT NULL,
	Timestamp TIMESTAMP DEFAULT (now() at time zone 'utc'),
	Version INT NOT NULL DEFAULT 0,

	CONSTRAINT PK_OrleansMembershipVersionTable_DeploymentId PRIMARY KEY(DeploymentId)
);

-- Every silo instance has a row in the membership table.
CREATE TABLE OrleansMembershipTable
(
	DeploymentId VARCHAR(150) NOT NULL,
	Address VARCHAR(45) NOT NULL,
	Port INT NOT NULL,
	Generation INT NOT NULL,
	HostName VARCHAR(150) NOT NULL,
	Status INT NOT NULL,
	ProxyPort INT NULL,
	SuspectTimes VARCHAR(8000) NULL,
	StartTime TIMESTAMP NOT NULL,
	IAmAliveTime TIMESTAMP NOT NULL,
	
	CONSTRAINT PK_MembershipTable_DeploymentId PRIMARY KEY(DeploymentId, Address, Port, Generation),
	CONSTRAINT FK_MembershipTable_MembershipVersionTable_DeploymentId FOREIGN KEY (DeploymentId) REFERENCES OrleansMembershipVersionTable (DeploymentId)
);

-- Orleans Reminders table - http://dotnet.github.io/orleans/Advanced-Concepts/Timers-and-Reminders
CREATE TABLE OrleansRemindersTable
(
	ServiceId VARCHAR(150) NOT NULL,
	GrainId VARCHAR(150) NOT NULL,
	ReminderName VARCHAR(150) NOT NULL,
	StartTime TIMESTAMP NOT NULL,
	Period INT NOT NULL,
	GrainHash INT NOT NULL,
	Version INT NOT NULL,

	CONSTRAINT PK_RemindersTable_ServiceId_GrainId_ReminderName PRIMARY KEY(ServiceId, GrainId, ReminderName)
);



CREATE TABLE OrleansStatisticsTable
(
	OrleansStatisticsTableId SERIAL PRIMARY KEY,
	DeploymentId VARCHAR(150) NOT NULL,
	Timestamp TIMESTAMP DEFAULT (now() at time zone 'utc'),
	Id VARCHAR(250) NOT NULL,
	HostName VARCHAR(150) NOT NULL,
	Name VARCHAR(150) NOT NULL,
	IsValueDelta BIT NOT NULL,
	StatValue VARCHAR(1024) NOT NULL,
	Statistic VARCHAR(512) NOT NULL	
);

CREATE TABLE OrleansClientMetricsTable
(
	DeploymentId VARCHAR(150) NOT NULL,
	ClientId VARCHAR(150) NOT NULL,
	Timestamp TIMESTAMP DEFAULT (now() at time zone 'utc'),
	Address VARCHAR(45) NOT NULL,
	HostName VARCHAR(150) NOT NULL,
	CpuUsage FLOAT NOT NULL,
	MemoryUsage BIGINT NOT NULL,
	SendQueueLength INT NOT NULL,
	ReceiveQueueLength INT NOT NULL,
	SentMessages BIGINT NOT NULL,
	ReceivedMessages BIGINT NOT NULL,
	ConnectedGatewayCount BIGINT NOT NULL,

	CONSTRAINT PK_ClientMetricsTable_DeploymentId_ClientId PRIMARY KEY (DeploymentId , ClientId)
);

CREATE TABLE OrleansSiloMetricsTable
(
	DeploymentId VARCHAR(150) NOT NULL,
	SiloId VARCHAR(150) NOT NULL,
	Timestamp TIMESTAMP DEFAULT (now() at time zone 'utc'),
	Address VARCHAR(45) NOT NULL,
	Port INT NOT NULL,
	Generation INT NOT NULL,
	HostName VARCHAR(150) NOT NULL,
	GatewayAddress VARCHAR(45) NOT NULL,
	GatewayPort INT NOT NULL,
	CpuUsage FLOAT NOT NULL,
	MemoryUsage BIGINT NOT NULL,
	SendQueueLength INT NOT NULL,
	ReceiveQueueLength INT NOT NULL,
	SentMessages BIGINT NOT NULL,
	ReceivedMessages BIGINT NOT NULL,
	ActivationCount INT NOT NULL,
	RecentlyUsedActivationCount INT NOT NULL,
	RequestQueueLength BIGINT NOT NULL,
	IsOverloaded BIT NOT NULL,
	ClientCount BIGINT NOT NULL,

	CONSTRAINT PK_SiloMetricsTable_DeploymentId_SiloId PRIMARY KEY (DeploymentId , SiloId),
	CONSTRAINT FK_SiloMetricsTable_MembershipVersionTable_DeploymentId FOREIGN KEY (DeploymentId) REFERENCES OrleansMembershipVersionTable (DeploymentId)
);

CREATE OR REPLACE FUNCTION InsertMembershipKey(
    l_deploymentid VARCHAR(150),
    l_port INT,
    l_address VARCHAR(45),
    l_generation INT,
    l_hostname VARCHAR(150),
    l_status INT,
    l_proxyport INT,
    l_starttime TIMESTAMP,
    l_iamalivetime TIMESTAMP)
  RETURNS INT AS
$BODY$
DECLARE 
	l_affected_rows INT := 0;	
BEGIN 		 
	WITH inserts AS (
	INSERT INTO OrleansMembershipTable (DeploymentId, Address, Port, Generation, HostName, Status, ProxyPort, StartTime, IAmAliveTime)
	SELECT l_deploymentId, l_address, l_port, l_generation, l_hostName, l_status, l_proxyPort, l_startTime, l_iAmAliveTime		
	WHERE not exists (
			SELECT 1	
			FROM OrleansMembershipTable 
			WHERE DeploymentId = l_deploymentId AND l_deploymentId IS NOT NULL
			AND Address = l_address AND l_address IS NOT NULL
			AND Port = l_port AND l_port IS NOT NULL
			AND Generation = l_generation AND l_generation IS NOT NULL
		)
	    RETURNING 1
	)
	SELECT count(*) INTO l_affected_rows FROM inserts;		
	WITH updates AS (
	UPDATE OrleansMembershipVersionTable
	SET 
		Timestamp = (now() at time zone 'utc'),
		Version = Version + 1
	WHERE DeploymentId = l_deploymentId AND l_deploymentId IS NOT NULL
	AND Version = @Version AND @Version IS NOT NULL
	AND l_affected_rows > 0
	RETURNING 1
	)
	SELECT count(*) INTO l_affected_rows FROM updates;		
	IF l_affected_rows = 0 then 
		ROLLBACK;		
		RETURN l_affected_rows;		
	END IF;		
	RETURN l_affected_rows;
EXCEPTION WHEN others THEN RETURN 0;
END
$BODY$
LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION UpdateMembershipKey(
    l_deploymentid VARCHAR(150),
    l_port INT,
    l_address VARCHAR(150),
    l_generation INT,
    l_version INT,
    l_status INT,
    l_suspectTimes VARCHAR(8000),
    l_iamalivetime TIMESTAMP
)
RETURNS integer AS
$BODY$
DECLARE 
	l_affected_rows INT := 0;	
BEGIN
	WITH versionUpdates AS (
	UPDATE OrleansMembershipVersionTable
	SET
		Timestamp = (now() at time zone 'utc'),
		Version = Version + 1
	WHERE
		DeploymentId = l_deploymentid AND l_deploymentid IS NOT NULL
		AND Version = l_version AND l_version IS NOT NULL
	RETURNING 1
	)
	SELECT count(*) INTO l_affected_rows FROM versionUpdates;
	WITH membershipUpdates AS (
	UPDATE OrleansMembershipTable
	SET
		Status = l_status,
		SuspectTimes = l_suspectTimes,
		IAmAliveTime = l_iamalivetime
	WHERE
		DeploymentId = l_deploymentid AND l_deploymentid IS NOT NULL
		AND Address = l_address AND l_address IS NOT NULL
		AND Port = l_port AND l_port IS NOT NULL
		AND Generation = l_generation AND l_generation IS NOT NULL
		AND l_affected_rows > 0
	RETURNING 1
	)
	SELECT count(*) INTO l_affected_rows FROM membershipUpdates;		
	IF l_affected_rows = 0 then 
		ROLLBACK;		
		RETURN l_affected_rows;		
	END IF;		
	RETURN l_affected_rows;	
EXCEPTION WHEN others THEN RETURN l_affected_rows;
END
$BODY$ LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION UpsertReminderRowKey(
	l_serviceId VARCHAR(150),
	l_grainId VARCHAR(150),
	l_reminderName VARCHAR(150),
	l_startTime TIMESTAMP,
	l_period INT,
	l_grainHash INT	
)
RETURNS integer AS
$BODY$
DECLARE 
	l_affected_rows INT := 0;	
	l_version INT := 0;
BEGIN
	WITH updates AS (
	UPDATE OrleansRemindersTable
	SET
		StartTime = l_startTime,
		Period = l_period,
		GrainHash = l_grainHash,
		l_version = Version = Version + 1
	WHERE
		ServiceId = l_serviceId AND l_serviceId IS NOT NULL
		AND GrainId = l_grainId AND l_grainId IS NOT NULL
		AND ReminderName = l_reminderName AND l_reminderName IS NOT NULL
	RETURNING 1
	)
	SELECT count(*) INTO l_affected_rows FROM updates;	
	INSERT INTO OrleansRemindersTable
	(
		ServiceId,
		GrainId,
		ReminderName,
		StartTime,
		Period,
		GrainHash,
		Version
	)
	SELECT
		l_serviceId,
		l_grainId,
		l_reminderName,
		l_startTime,
		l_period,
		l_grainHash,
		0
	WHERE
		l_affected_rows = 0;
	SELECT l_version AS Version;
EXCEPTION WHEN others THEN RETURN 0;
END
$BODY$ LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION UpsertReportClientMetricsKey(
	l_deploymentId VARCHAR(150),
	l_clientId VARCHAR(150),
	l_address VARCHAR(45),
	l_hostName VARCHAR(150),
	l_cpuUsage FLOAT,
	l_memoryUsage BIGINT,
	l_sendQueueLength INT,
	l_receiveQueueLength INT,
	l_sentMessages BIGINT,
	l_receivedMessages BIGINT,
	l_connectedGatewayCount BIGINT	
)
RETURNS integer AS
$BODY$
DECLARE 
	l_affected_rows INT := 0;	
BEGIN
	WITH updates AS (
	UPDATE OrleansClientMetricsTable
	SET
		Timestamp = (now() at time zone 'utc'),
		Address = l_address,
		HostName = l_hostName,
		CpuUsage = l_cpuUsage,
		MemoryUsage = l_memoryUsage,
		SendQueueLength = l_sendQueueLength,
		ReceiveQueueLength = l_receiveQueueLength,
		SentMessages = l_sentMessages,
		ReceivedMessages = l_receivedMessages,
		ConnectedGatewayCount = l_connectedGatewayCount
	WHERE
		DeploymentId = l_deploymentId AND l_deploymentId IS NOT NULL
		AND ClientId = l_clientId AND l_clientId IS NOT NULL
	RETURNING 1
	)
	SELECT count(*) INTO l_affected_rows FROM updates;
	WITH inserts AS (	
	INSERT INTO OrleansClientMetricsTable
	(
		DeploymentId,
		ClientId,
		Address,			
		HostName,
		CpuUsage,
		MemoryUsage,
		SendQueueLength,
		ReceiveQueueLength,
		SentMessages,
		ReceivedMessages,
		ConnectedGatewayCount
	)
	SELECT
		l_deploymentId,
		l_clientId,
		l_address,			
		l_hostName,
		l_cpuUsage,
		l_memoryUsage,
		l_sendQueueLength,
		l_receiveQueueLength,
		l_sentMessages,
		l_receivedMessages,
		l_connectedGatewayCount	
	WHERE
		l_affected_rows = 0
	RETURNING 1
	)
	SELECT count(*) INTO l_affected_rows FROM inserts;
	RETURN l_affected_rows;
EXCEPTION WHEN others THEN RETURN 0;
END
$BODY$ LANGUAGE plpgsql VOLATILE;


CREATE OR REPLACE FUNCTION UpsertSiloMetricsKey(
	l_deploymentId VARCHAR(150),
	l_siloId VARCHAR(150),
	l_address VARCHAR(45),
	l_port INT,
	l_generation INT,
	l_hostName VARCHAR(150),
	l_gatewayAddress VARCHAR(45),
	l_gatewayPort INT,
	l_cpuUsage FLOAT,
	l_memoryUsage BIGINT,
	l_sendQueueLength INT,
	l_receiveQueueLength INT,
	l_sentMessages BIGINT,	
	l_receivedMessages BIGINT,
	l_activationCount INT,
	l_recentlyUsedActivationCount INT,
	l_requestQueueLength BIGINT,
	l_isOverloaded BIT,
	l_clientCount BIGINT
)
RETURNS integer AS
$BODY$
DECLARE 
	l_affected_rows INT := 0;	
BEGIN
	WITH updates AS (
	UPDATE OrleansSiloMetricsTable
	SET
		Timestamp = (now() at time zone 'utc'),
		Address = l_address,
		Port = l_port,
		Generation = l_generation,
		HostName = l_hostName,
		GatewayAddress = l_gatewayAddress,
		GatewayPort = l_gatewayPort,
		CpuUsage = l_cpuUsage,
		MemoryUsage = l_memoryUsage,
		ActivationCount = l_activationCount,
		RecentlyUsedActivationCount = l_recentlyUsedActivationCount,
		SendQueueLength = l_sendQueueLength,
		ReceiveQueueLength = l_receiveQueueLength,
		RequestQueueLength = l_requestQueueLength,
		SentMessages = l_sentMessages,
		ReceivedMessages = l_receivedMessages,
		IsOverloaded = l_isOverloaded,
		ClientCount = l_clientCount
	WHERE
		DeploymentId = l_deploymentId AND l_deploymentId IS NOT NULL
		AND SiloId = l_siloId AND l_siloId IS NOT NULL
	RETURNING 1
	)	
	SELECT count(*) INTO l_affected_rows FROM updates;
	WITH inserts AS (	
	INSERT INTO OrleansSiloMetricsTable
	(
		DeploymentId,
		SiloId,
		Address,
		Port,
		Generation,
		HostName,
		GatewayAddress,
		GatewayPort,
		CpuUsage,
		MemoryUsage,
		SendQueueLength,
		ReceiveQueueLength,
		SentMessages,	
		ReceivedMessages,
		ActivationCount,
		RecentlyUsedActivationCount,
		RequestQueueLength,
		IsOverloaded,
		ClientCount
	)
	SELECT
		l_deploymentId,
		l_siloId,
		l_address,
		l_port,
		l_generation,
		l_hostName,
		l_gatewayAddress,
		l_gatewayPort,
		l_cpuUsage,
		l_memoryUsage,
		l_sendQueueLength,
		l_receiveQueueLength,
		l_sentMessages,	
		l_receivedMessages,
		l_activationCount,
		l_recentlyUsedActivationCount,
		l_requestQueueLength,
		l_isOverloaded,
		l_clientCount
	WHERE
		l_affected_rows = 0
	RETURNING 1
	)
	SELECT count(*) INTO l_affected_rows FROM inserts;
	RETURN l_affected_rows;
EXCEPTION WHEN others THEN RETURN 0;
END
$BODY$ LANGUAGE plpgsql VOLATILE;



INSERT INTO OrleansQuery(QueryKey, QueryText)
VALUES
(
	'UpdateIAmAlivetimeKey','
	-- This is expected to never fail by Orleans, so return value
	-- is not needed nor is it checked.	
	UPDATE OrleansMembershipTable
	SET
		IAmAliveTime = @IAmAliveTime
	WHERE DeploymentId = @DeploymentId AND @DeploymentId IS NOT NULL
	AND Address = @Address AND @Address IS NOT NULL
	AND Port = @Port AND @Port IS NOT NULL
	AND Generation = @Generation AND @Generation IS NOT NULL;
');

INSERT INTO OrleansQuery(QueryKey, QueryText)
VALUES
(
	'InsertMembershipVersionKey','
	WITH rows AS (
    INSERT INTO OrleansMembershipVersionTable (DeploymentId)
    SELECT @DeploymentId WHERE NOT EXISTS (SELECT 1 FROM OrleansMembershipVersionTable WHERE DeploymentId = @DeploymentId AND @DeploymentId IS NOT NULL) 
    RETURNING 1
	)
	SELECT count(*) FROM rows;
');

INSERT INTO OrleansQuery(QueryKey, QueryText)
VALUES
(
	'InsertMembershipKey','
	SELECT public.InsertMembershipKey(
	l_deploymentid := @DeploymentId,
	l_address := @Address,
	l_port := @Port,
	l_generation := @Generation,
	l_hostname := @HostName,
	l_status := @Status,
	l_proxyport := @ProxyPort,
	l_starttime := @StartTime,
	l_iamalivetime := @IAmAliveTime);
');

INSERT INTO OrleansQuery(QueryKey, QueryText)
VALUES
(
	'UpdateMembershipKey','
	SELECT public.UpdateMembershipKey(
    l_deploymentid := @DeploymentId,
    l_port := @Port,
    l_address := @Address,
    l_generation := @Generation,
    l_version := @Version,
    l_status := @Status,
    l_suspectTimes := @SuspectTimes,
    l_iamalivetime := @IAmAliveTime);
');

INSERT INTO OrleansQuery(QueryKey, QueryText)
VALUES
(
	'UpsertReminderRowKey','
	SELECT public.UpsertReminderRowKey(
    l_serviceid := @Serviceid,
    l_grainid := @Grainid,
    l_remindername := @Remindername,
    l_starttime := @StartTime,
    l_period := @Period,
    l_grainhash := @GrainHash);
');

INSERT INTO OrleansQuery(QueryKey, QueryText)
VALUES
(
	'UpsertReportClientMetricsKey','
	SELECT public.UpsertReportClientMetricsKey(
	l_deploymentId := @DeploymentId,
	l_clientId := @ClientId,
	l_address := @Address,	
	l_hostName := @HostName,
	l_cpuUsage := @CpuUsage,
	l_memoryUsage := @MemoryUsage,
	l_sendQueueLength := @SendQueueLength,
	l_receiveQueueLength := @ReceiveQueueLength,
	l_sentMessages := @SentMessages,
	l_receivedMessages := @ReceivedMessages,
	l_connectedGatewayCount := @ConnectedGatewayCount);	
');

INSERT INTO OrleansQuery(QueryKey, QueryText)
VALUES
(
	'UpsertSiloMetricsKey','
	SELECT public.UpsertSiloMetricsKey(
	l_deploymentId := @DeploymentId,
	l_siloId := @SiloId,
	l_address := @Address,
	l_port := @Port,
	l_generation := @Generation,
	l_hostName := @HostName,
	l_gatewayAddress := @GatewayAddress,
	l_gatewayPort := @GatewayPort,
	l_cpuUsage := @CpuUsage,
	l_memoryUsage := @MemoryUsage,
	l_sendQueueLength := @SendQueueLength,
	l_receiveQueueLength := @ReceiveQueueLength,
	l_sentMessages := @SentMessages,	
	l_receivedMessages := @ReceivedMessages,
	l_activationCount := @ActivationCount,
	l_recentlyUsedActivationCount := @RecentlyUsedActivationCount,
	l_requestQueueLength := @RequestQueueLength,
	l_isOverloaded := @IsOverloaded,
	l_clientCount := @ClientCount);
');

INSERT INTO OrleansQuery(QueryKey, QueryText)
VALUES
(
	'GatewaysQueryKey','
	SELECT
		Address,
		ProxyPort,
		Generation
	FROM
		OrleansMembershipTable
	WHERE
		DeploymentId = @DeploymentId AND @DeploymentId IS NOT NULL
		AND Status = @Status AND @Status IS NOT NULL
		AND ProxyPort > 0;
');

INSERT INTO OrleansQuery(QueryKey, QueryText)
VALUES
(
	'MembershipReadRowKey','
	SELECT
		v.DeploymentId,
		m.Address,
		m.Port,
		m.Generation,
		m.HostName,
		m.Status,
		m.ProxyPort,
		m.SuspectTimes,
		m.StartTime,
		m.IAmAliveTime,
		v.Version
	FROM
		OrleansMembershipVersionTable v
		-- This ensures the version table will returned even if there is no matching membership row.
		LEFT OUTER JOIN OrleansMembershipTable m ON v.DeploymentId = m.DeploymentId	
		AND Address = @Address AND @Address IS NOT NULL
		AND Port = @Port AND @Port IS NOT NULL
		AND Generation = @Generation AND @Generation IS NOT NULL
	WHERE 
		v.DeploymentId = @DeploymentId AND @DeploymentId IS NOT NULL;
');

INSERT INTO OrleansQuery(QueryKey, QueryText)
VALUES
(
	'MembershipReadAllKey','
	SELECT
		v.DeploymentId,
		m.Address,
		m.Port,
		m.Generation,
		m.HostName,
		m.Status,
		m.ProxyPort,
		m.SuspectTimes,
		m.StartTime,
		m.IAmAliveTime,
		v.Version
	FROM
		OrleansMembershipVersionTable v LEFT OUTER JOIN OrleansMembershipTable m
		ON v.DeploymentId = m.DeploymentId
	WHERE
		v.DeploymentId = @DeploymentId AND @DeploymentId IS NOT NULL;
');

INSERT INTO OrleansQuery(QueryKey, QueryText)
VALUES
(
	'DeleteMembershipTableEntriesKey','
	DELETE FROM OrleansMembershipTable
	WHERE DeploymentId = @DeploymentId AND @DeploymentId IS NOT NULL;
	DELETE FROM OrleansMembershipVersionTable
	WHERE DeploymentId = @DeploymentId AND @DeploymentId IS NOT NULL;
');

INSERT INTO OrleansQuery(QueryKey, QueryText)
VALUES
(
	'ReadReminderRowsKey','
	SELECT
		GrainId,
		ReminderName,
		StartTime,
		Period,
		Version
	FROM OrleansRemindersTable
	WHERE
		ServiceId = @ServiceId AND @ServiceId IS NOT NULL
		AND GrainId = @GrainId AND @GrainId IS NOT NULL;
');

INSERT INTO OrleansQuery(QueryKey, QueryText)
VALUES
(
	'ReadReminderRowKey','
	SELECT
		GrainId,
		ReminderName,
		StartTime,
		Period,
		Version
	FROM OrleansRemindersTable
	WHERE
		ServiceId = @ServiceId AND @ServiceId IS NOT NULL
		AND GrainId = @GrainId AND @GrainId IS NOT NULL
		AND ReminderName = @ReminderName AND @ReminderName IS NOT NULL;
');

INSERT INTO OrleansQuery(QueryKey, QueryText)
VALUES
(
	'ReadRangeRows1Key','
	SELECT
		GrainId,
		ReminderName,
		StartTime,
		Period,
		Version
	FROM OrleansRemindersTable
	WHERE
		ServiceId = @ServiceId AND @ServiceId IS NOT NULL
		AND GrainHash > @BeginHash AND @BeginHash IS NOT NULL
		AND GrainHash <= @EndHash AND @EndHash IS NOT NULL;
');

INSERT INTO OrleansQuery(QueryKey, QueryText)
VALUES
(
	'ReadRangeRows2Key','
	SELECT
		GrainId,
		ReminderName,
		StartTime,
		Period,
		Version
	FROM OrleansRemindersTable
	WHERE
		ServiceId = @ServiceId AND @ServiceId IS NOT NULL
		AND ((GrainHash > @BeginHash AND @BeginHash IS NOT NULL)
		OR (GrainHash <= @EndHash AND @EndHash IS NOT NULL));
');

INSERT INTO OrleansQuery(QueryKey, QueryText)
VALUES
(
	'InsertOrleansStatisticsKey','	
	WITH rows AS (
  	INSERT INTO OrleansStatisticsTable
	(
		DeploymentId,
		Id,
		HostName,
		Name,
		IsValueDelta,
		StatValue,
		Statistic
	)
	SELECT
		@DeploymentId,
		@Id,
		@HostName,
		@Name,
		@IsValueDelta,
		@StatValue,
		@Statistic;
    RETURNING 1
	)
	SELECT count(*) FROM rows;
');

INSERT INTO OrleansQuery(QueryKey, QueryText)
VALUES
(
	'DeleteReminderRowKey','
	WITH rows AS (
	DELETE FROM OrleansRemindersTable
	WHERE
		ServiceId = @ServiceId AND @ServiceId IS NOT NULL
		AND GrainId = @GrainId AND @GrainId IS NOT NULL
		AND ReminderName = @ReminderName AND @ReminderName IS NOT NULL
		AND Version = @Version AND @Version IS NOT NULL;
	RETURNING 1
	)
	SELECT count(*) FROM rows;
');

INSERT INTO OrleansQuery(QueryKey, QueryText)
VALUES
(
	'DeleteReminderRowsKey','
	DELETE FROM OrleansRemindersTable
	WHERE 
		ServiceId = @ServiceId AND @ServiceId IS NOT NULL;
');
