#!/usr/bin/env Rscript

# Migration script to convert SQLite database to DuckDB
# Run this script if you have an existing SQLite database and want to migrate to DuckDB

# Install and load required packages
if (!require(duckdb)) install.packages("duckdb")
if (!require(RSQLite)) install.packages("RSQLite")

library(DBI)
library(duckdb)
library(RSQLite)
library(data.table)

# Migration function
migrate_sqlite_to_duckdb <- function(sqlite_path, duckdb_path) {
  cat("Starting migration from SQLite to DuckDB...\n")
  cat("SQLite source:", sqlite_path, "\n")
  cat("DuckDB destination:", duckdb_path, "\n\n")
  
  # Connect to both databases
  sqlite_con <- dbConnect(RSQLite::SQLite(), sqlite_path)
  duckdb_con <- dbConnect(duckdb::duckdb(), duckdb_path)
  
  # Get all table names from SQLite
  tables <- dbListTables(sqlite_con)
  cat("Found", length(tables), "tables to migrate:\n")
  cat(paste(tables, collapse = ", "), "\n\n")
  
  total_rows <- 0
  
  for (table in tables) {
    cat("Migrating table:", table, "\n")
    
    # Read from SQLite
    data <- dbReadTable(sqlite_con, table)
    cat("  - Read", nrow(data), "rows\n")
    
    # Write to DuckDB (automatically creates optimized schema)
    dbWriteTable(duckdb_con, table, data, overwrite = TRUE)
    cat("  - Written to DuckDB\n")
    
    total_rows <- total_rows + nrow(data)
  }
  
  # Get and migrate views
  cat("\nMigrating views...\n")
  views_query <- "SELECT name FROM sqlite_master WHERE type='view'"
  views <- dbGetQuery(sqlite_con, views_query)$name
  
  for (view in views) {
    cat("Migrating view:", view, "\n")
    
    # Get view definition
    view_def_query <- paste("SELECT sql FROM sqlite_master WHERE type='view' AND name='", view, "'", sep="")
    view_def <- dbGetQuery(sqlite_con, view_def_query)$sql
    
    # Convert SQLite view syntax to DuckDB (basic conversion)
    view_def_duckdb <- gsub("CREATE VIEW", "CREATE OR REPLACE VIEW", view_def)
    
    tryCatch({
      dbExecute(duckdb_con, view_def_duckdb)
      cat("  - View created successfully\n")
    }, error = function(e) {
      cat("  - Warning: Could not create view:", e$message, "\n")
    })
  }
  
  # Get and migrate indexes
  cat("\nMigrating indexes...\n")
  indexes_query <- "SELECT name, sql FROM sqlite_master WHERE type='index' AND sql IS NOT NULL"
  indexes <- dbGetQuery(sqlite_con, indexes_query)
  
  for (i in 1:nrow(indexes)) {
    index_name <- indexes$name[i]
    index_sql <- indexes$sql[i]
    
    cat("Migrating index:", index_name, "\n")
    
    # Convert SQLite index syntax to DuckDB
    index_sql_duckdb <- gsub("CREATE INDEX", "CREATE INDEX IF NOT EXISTS", index_sql)
    
    tryCatch({
      dbExecute(duckdb_con, index_sql_duckdb)
      cat("  - Index created successfully\n")
    }, error = function(e) {
      cat("  - Warning: Could not create index:", e$message, "\n")
    })
  }
  
  dbDisconnect(sqlite_con)
  dbDisconnect(duckdb_con)
  
  cat("\n=== MIGRATION COMPLETED ===\n")
  cat("Total tables migrated:", length(tables), "\n")
  cat("Total rows migrated:", total_rows, "\n")
  cat("Views migrated:", length(views), "\n")
  cat("Indexes migrated:", nrow(indexes), "\n")
  cat("DuckDB database created at:", duckdb_path, "\n")
}

# Example usage
if (FALSE) {  # Set to TRUE to run migration
  # Replace these paths with your actual file paths
  sqlite_path <- "indo_swiss_research.db"
  duckdb_path <- "indo_swiss_research.duckdb"
  
  migrate_sqlite_to_duckdb(sqlite_path, duckdb_path)
}

# Function to compare database contents
compare_databases <- function(sqlite_path, duckdb_path) {
  cat("Comparing SQLite and DuckDB databases...\n\n")
  
  sqlite_con <- dbConnect(RSQLite::SQLite(), sqlite_path)
  duckdb_con <- dbConnect(duckdb::duckdb(), duckdb_path)
  
  # Get table names
  sqlite_tables <- dbListTables(sqlite_con)
  duckdb_tables <- dbListTables(duckdb_con)
  
  cat("Tables in SQLite:", length(sqlite_tables), "\n")
  cat("Tables in DuckDB:", length(duckdb_tables), "\n\n")
  
  # Compare row counts for each table
  for (table in sqlite_tables) {
    if (table %in% duckdb_tables) {
      sqlite_count <- dbGetQuery(sqlite_con, paste("SELECT COUNT(*) as n FROM", table))$n
      duckdb_count <- dbGetQuery(duckdb_con, paste("SELECT COUNT(*) as n FROM", table))$n
      
      cat(sprintf("%-20s: SQLite=%d, DuckDB=%d, Match=%s\n", 
                  table, sqlite_count, duckdb_count, 
                  ifelse(sqlite_count == duckdb_count, "✓", "✗")))
    } else {
      cat(sprintf("%-20s: Missing in DuckDB\n", table))
    }
  }
  
  dbDisconnect(sqlite_con)
  dbDisconnect(duckdb_con)
}

# Example usage for comparison
if (FALSE) {  # Set to TRUE to run comparison
  sqlite_path <- "indo_swiss_research.db"
  duckdb_path <- "indo_swiss_research.duckdb"
  
  compare_databases(sqlite_path, duckdb_path)
}

cat("Migration script loaded. Use migrate_sqlite_to_duckdb() to migrate your database.\n")
cat("Use compare_databases() to verify the migration was successful.\n")
