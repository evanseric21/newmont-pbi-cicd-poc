/*
  Newmont CI/CD POC - sample data seed. Run once per database:

    newmont_test  -> Dev / QA  (simulates the Databricks test catalog)        Multiplier = 1.0
    newmont_prod  -> Prod      (simulates the Databricks production catalog)  Multiplier = 1.5

  Both databases use the schema "gold", so catalog = database and schema = gold, mirroring
  Databricks Unity Catalog "catalog.schema". Prod values are 1.5x test values so it is obvious
  which catalog a deployed model is bound to. All data is fictional.

    sqlcmd -S <server>.database.windows.net -d newmont_test -U <admin> -P <pwd> -i sql/seed.sql `
      -v Multiplier="1.0" ReaderUser="pbi_reader" ReaderPassword="<strong-password>"
    sqlcmd -S <server>.database.windows.net -d newmont_prod -U <admin> -P <pwd> -i sql/seed.sql `
      -v Multiplier="1.5" ReaderUser="pbi_reader" ReaderPassword="<strong-password>"
*/
SET NOCOUNT ON;
GO

IF SCHEMA_ID(N'gold') IS NULL EXEC(N'CREATE SCHEMA gold');
GO

DROP TABLE IF EXISTS gold.FactProduction;
DROP TABLE IF EXISTS gold.DimSite;
DROP TABLE IF EXISTS gold.DimDate;
GO

CREATE TABLE gold.DimSite (
    SiteKey   int           NOT NULL PRIMARY KEY,
    SiteName  nvarchar(50)  NOT NULL,
    Region    nvarchar(50)  NOT NULL,
    Country   nvarchar(50)  NOT NULL);

INSERT gold.DimSite VALUES
    (1, N'Site NA-01', N'North America', N'United States'),
    (2, N'Site NA-02', N'North America', N'Canada'),
    (3, N'Site LA-01', N'Latin America', N'Mexico'),
    (4, N'Site AF-01', N'Africa',        N'Ghana'),
    (5, N'Site AU-01', N'Australia',     N'Australia'),
    (6, N'Site AP-01', N'Asia Pacific',  N'Papua New Guinea');

CREATE TABLE gold.DimDate (
    DateKey     int          NOT NULL PRIMARY KEY,
    [Date]      date         NOT NULL,
    [Year]      int          NOT NULL,
    MonthNumber int          NOT NULL,
    MonthName   nvarchar(10) NOT NULL);

;WITH m AS (SELECT TOP (12) ROW_NUMBER() OVER (ORDER BY (SELECT 1)) AS n FROM sys.objects)
INSERT gold.DimDate
SELECT CONVERT(int, FORMAT(d, 'yyyyMMdd')), d, YEAR(d), MONTH(d), DATENAME(month, d)
FROM (SELECT DATEFROMPARTS(2026, n, 1) AS d FROM m) x;

CREATE TABLE gold.FactProduction (
    DateKey    int            NOT NULL REFERENCES gold.DimDate(DateKey),
    SiteKey    int            NOT NULL REFERENCES gold.DimSite(SiteKey),
    GoldOunces decimal(18,2)  NOT NULL,
    OreTonnes  decimal(18,2)  NOT NULL,
    CostUSD    decimal(18,2)  NOT NULL);
GO

DECLARE @m decimal(9,4) = CAST(N'$(Multiplier)' AS decimal(9,4));
INSERT gold.FactProduction
SELECT d.DateKey, s.SiteKey,
       CAST((1000 + s.SiteKey * 250 + d.MonthNumber * 10) * @m AS decimal(18,2)),
       CAST((50000 + s.SiteKey * 4000 + d.MonthNumber * 500) * @m AS decimal(18,2)),
       CAST((1000 + s.SiteKey * 250 + d.MonthNumber * 10) * (1200 + s.SiteKey * 15) * @m AS decimal(18,2))
FROM gold.DimDate d CROSS JOIN gold.DimSite s;
GO

-- Read-only contained user used by the gateway connection and the pipeline data-validation step.
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'$(ReaderUser)')
    CREATE USER [$(ReaderUser)] WITH PASSWORD = N'$(ReaderPassword)';
ELSE
    ALTER USER [$(ReaderUser)] WITH PASSWORD = N'$(ReaderPassword)';
ALTER ROLE db_datareader ADD MEMBER [$(ReaderUser)];
GO

SELECT DB_NAME() AS [Database], COUNT(*) AS FactRows, SUM(GoldOunces) AS GoldOunces FROM gold.FactProduction;
GO
