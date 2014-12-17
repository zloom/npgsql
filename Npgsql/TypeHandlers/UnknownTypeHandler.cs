﻿using System;
using System.Collections.Generic;
using System.Diagnostics.Contracts;
using System.Linq;
using System.Text;
using Npgsql.Messages;

namespace Npgsql.TypeHandlers
{
    /// <summary>
    /// Handles "conversions" for columns sent by the database with unknown OIDs.
    /// Note that this also happens in the very initial query that loads the OID mappings (chicken and egg problem).
    /// </summary>
    internal class UnknownTypeHandler : TypeHandler<string>
    {
        static readonly string[] _pgNames = { "unknown" };
        internal override string[] PgNames { get { return _pgNames; } }

        public override string Read(NpgsqlBuffer buf, FieldDescription fieldDescription, int len)
        {
            return buf.ReadString(len);
        }
    }
}