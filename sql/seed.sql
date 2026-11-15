/*
  Newmont CI/CD POC - sample data seed (Azure SQL Database: newmont_poc)

  Simulates Databricks Unity Catalog "catalog.schema" with SQL schemas:
    test_gold  -> Dev / QA   (Databricks test)
    prod_gold  -> Prod       (Databricks production)

  Prod values are 1.5x test values so it is obvious which "catalog" a model is bound to.
  All data is fictional.

  Run with sqlcmd (variables are required):
    sqlcmd -S <server>.database.windows.net -d newmont_poc -U <admin> -P <pwd> -i sql/seed.sql `
      -v ReaderUser="pbi_reader" ReaderPassword="<strong-password>"
*/
SET NOCOUNT ON;
GO

DECLARE @schemas TABLE (SchemaName sysname, Multiplier decimal(9,4));
INSERT @schemas VALUES ('test_gold', 1.0), ('prod_gold', 1.5);

DECLARE @s sysname, @m decimal(9,4), @sql nvarchar(max);
DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT SchemaName, Multiplier FROM @schemas;
OPEN c;
FETCH NEXT FROM c INTO @s, @m;
WHILE @@FETCH_STATUS = 0
BEGIN
    IF SCHEMA_ID(@s) IS NULL EXEC('CREATE SCHEMA ' + @s);

    SET @sql = N'
    DROP TABLE IF EXISTS ' + @s + N'.FactProduction;
    DROP TABLE IF EXISTS ' + @s + N'.DimSite;
    DROP TABLE IF EXISTS ' + @s + N'.DimDate;

    CREATE TABLE ' + @s + N'.DimSite (
        SiteKey   int           NOT NULL PRIMARY KEY,
        SiteName  nvarchar(50)  NOT NULL,
        Region    nvarchar(50)  NOT NULL,
        Country   nvarchar(50)  NOT NULL);

    INSERT ' + @s + N'.DimSite VALUES
        (1, N''Site NA-01'', N''North America'', N''United States''),
        (2, N''Site NA-02'', N''North America'', N''Canada''),
        (3, N''Site LA-01'', N''Latin America'', N''Mexico''),
        (4, N''Site AF-01'', N''Africa'',        N''Ghana''),
        (5, N''Site AU-01'', N''Australia'',     N''Australia''),
        (6, N''Site AP-01'', N''Asia Pacific'',  N''Papua New Guinea'');

    CREATE TABLE ' + @s + N'.DimDate (
        DateKey     int          NOT NULL PRIMARY KEY,
        [Date]      date         NOT NULL,
        [Year]      int          NOT NULL,
        MonthNumber int          NOT NULL,
        MonthName   nvarchar(10) NOT NULL);

    ;WITH m AS (SELECT TOP (12) ROW_NUMBER() OVER (ORDER BY (SELECT 1)) AS n FROM sys.objects)
    INSERT ' + @s + N'.DimDate
    SELECT CONVERT(int, FORMAT(d, ''yyyyMMdd'')), d, YEAR(d), MONTH(d), DATENAME(month, d)
    FROM (SELECT DATEFROMPARTS(2026, n, 1) AS d FROM m) x;

    CREATE TABLE ' + @s + N'.FactProduction (
        DateKey    int            NOT NULL REFERENCES ' + @s + N'.DimDate(DateKey),
        SiteKey    int            NOT NULL REFERENCES ' + @s + N'.DimSite(SiteKey),
        GoldOunces decimal(18,2)  NOT NULL,
        OreTonnes  decimal(18,2)  NOT NULL,
        CostUSD    decimal(18,2)  NOT NULL);

    INSERT ' + @s + N'.FactProduction
    SELECT d.DateKey, s.SiteKey,
           CAST((1000 + s.SiteKey * 250 + d.MonthNumber * 10) * @m AS decimal(18,2)),
           CAST((50000 + s.SiteKey * 4000 + d.MonthNumber * 500) * @m AS decimal(18,2)),
           CAST((1000 + s.SiteKey * 250 + d.MonthNumber * 10) * (1200 + s.SiteKey * 15) * @m AS decimal(18,2))
    FROM ' + @s + N'.DimDate d CROSS JOIN ' + @s + N'.DimSite s;';

    EXEC sp_executesql @sql, N'@m decimal(9,4)', @m = @m;
    FETCH NEXT FROM c INTO @s, @m;
END
CLOSE c; DEALLOCATE c;
GO

-- Read-only contained user used by the gateway connection and the pipeline data-validation step.
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'$(ReaderUser)')
    CREATE USER [$(ReaderUser)] WITH PASSWORD = N'$(ReaderPassword)';
ELSE
    ALTER USER [$(ReaderUser)] WITH PASSWORD = N'$(ReaderPassword)';
ALTER ROLE db_datareader ADD MEMBER [$(ReaderUser)];
GO

SELECT 'test_gold' AS [Schema], COUNT(*) AS FactRows, SUM(GoldOunces) AS GoldOunces FROM test_gold.FactProduction
UNION ALL
SELECT 'prod_gold', COUNT(*), SUM(GoldOunces) FROM prod_gold.FactProduction;
GO
