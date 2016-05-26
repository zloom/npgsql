using System;
using System.Collections.Generic;
using System.Data;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using Npgsql.Logging;
using Orleans.Runtime.Configuration;
using Orleans.Runtime.Host;
using Orleans.SqlUtils;

namespace Npgsql.Orleans
{


    public class Provider : INpgsqlLoggingProvider
    {
        public NpgsqlLogger CreateLogger(string name)
        {
            return new Logger();
        }
    }

    public class Logger : NpgsqlLogger
    {
        public override bool IsEnabled(NpgsqlLogLevel level)
        {
            return true;
        }

        public override void Log(NpgsqlLogLevel level, int connectorId, string msg, Exception exception = null)
        {
            Console.WriteLine(msg);
            Trace.Write(msg);
        }
    }

    class Program
    {
      
        public static string connectionString = "Server=localhost; Port=5432; Database=orleans_system; User Id=postgres; Password = 123; CommandTimeout = 20; Pooling = true;";
        public static SiloHost siloHost;

        public static KeyValuePair<string, string> GetQueryKeyAndValue(IDataRecord record)
        {
            return new KeyValuePair<string, string>(record.GetValue<string>("QueryKey"),
                record.GetValue<string>("QueryText"));
        }



        public static void Init(string[] args)
        {
            var config = new ClusterConfiguration(new StringReader(File.ReadAllText("Host.xml")));
            siloHost = new SiloHost(System.Net.Dns.GetHostName(), config);
            siloHost.InitializeOrleansSilo();
            var startedok = siloHost.StartOrleansSilo();
            if (!startedok)
                throw new SystemException(string.Format("Failed to start Orleans silo '{0}' as a {1} node",
                    siloHost.Name, siloHost.Type));
        }

        static void Main(string[] args)
        {
            NpgsqlLogManager.Provider = new Provider();
            
            Console.WriteLine("!!!");
            Console.ReadKey();

            //when relational storage used outside silo all work fine.
            //var rs = RelationalStorage.CreateInstance("Npgsql", connectionString);
            //var result = rs.ReadAsync("SELECT QueryKey, QueryText FROM OrleansQuery;", GetQueryKeyAndValue, null).Result;


            //orleans silo use custom task manager and thread pool it maybe source of problem
            //npgsql 2.2.7 version also work fine 

            
            Init(args);

            Console.ReadKey();


        }


    }
}
