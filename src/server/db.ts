import { Pool } from "pg";

declare global {
  var appCriminalitePool: Pool | undefined;
}

const connectionString =
  process.env.DATABASE_URL ??
  "postgres://app:app_dev_password@localhost:5432/app_criminalite";

export const pool =
  globalThis.appCriminalitePool ??
  new Pool({
    connectionString,
    max: 10
  });

if (process.env.NODE_ENV !== "production") {
  globalThis.appCriminalitePool = pool;
}
