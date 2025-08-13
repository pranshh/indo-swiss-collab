
# Load required libraries
library(httr2)
library(jsonlite)
library(dplyr)
library(DBI)
library(RSQLite)
library(purrr)
library(tibble)
library(digest)

create_table_safe <- function(con, table_name, create_statement) {
  tryCatch({
    # Temporarily disable foreign key constraints
    dbExecute(con, "PRAGMA foreign_keys = OFF")
    
    dbExecute(con, paste("DROP TABLE IF EXISTS", table_name))
    dbExecute(con, create_statement)
    
    # Re-enable foreign key constraints
    dbExecute(con, "PRAGMA foreign_keys = ON")
    
    message(paste("Created table:", table_name))
  }, error = function(e) {
    # Re-enable foreign key constraints even if there's an error
    dbExecute(con, "PRAGMA foreign_keys = ON")
    message(paste("Error creating table", table_name, ":", e$message))
  })
}

# Function to fetch data with caching
fetch_openalex_data_cached <- function(endpoint, params = list(), cache_file = NULL, force_refresh = FALSE, delay = 0.1) {
  # Generate cache filename if not provided
  if (is.null(cache_file)) {
    param_hash <- digest::digest(paste(names(params), unlist(params), collapse = ""))
    cache_file <- paste0("cache_openalex_", endpoint, "_", param_hash, ".rds")
  }
  
  # Check if cache exists and we're not forcing refresh
  if (!force_refresh && file.exists(cache_file)) {
    cat("Loading cached data from", cache_file, "\n")
    tryCatch({
      cached_data <- readRDS(cache_file)
      cat("Loaded", length(cached_data), "records from cache\n")
      return(cached_data)
    }, error = function(e) {
      cat("Error reading cache file:", e$message, "\n")
      cat("Will fetch fresh data from API...\n")
    })
  }
  
  # Fetch fresh data from API
  cat("Fetching fresh data from OpenAlex API...\n")
  all_data <- list()
  page <- 1
  per_page <- 200  # Max allowed by OpenAlex
  
  repeat {
    cat("Fetching page", page, "from", endpoint, "\n")
    
    # Build request with pagination
    current_params <- c(params, list(page = page, `per-page` = per_page))
    
    response <- request("https://api.openalex.org") |>
      req_url_path_append(endpoint) |>
      req_url_query(!!!current_params) |>
      req_user_agent("R script for academic research (mailto:your-email@domain.com)") |>
      req_perform()
    
    data <- resp_body_json(response)
    
    # Check if we have results
    if (length(data$results) == 0) break
    
    all_data <- c(all_data, data$results)
    
    # Check if we've reached the end
    if (length(data$results) < per_page) break
    
    page <- page + 1
    Sys.sleep(delay)  # Be respectful to the API
  }
  
  # Save to cache
  cat("Saving", length(all_data), "records to cache file:", cache_file, "\n")
  saveRDS(all_data, cache_file)
  
  return(all_data)
}

# Function to extract domain data from OpenAlex response
extract_domains <- function(topics_data) {
  domains <- topics_data |>
    map_dfr(~ {
      domain_info <- .x$domain
      if (!is.null(domain_info)) {
        tibble(
          domain_id = sub("https://openalex.org/domains/", "", domain_info$id),
          display_name = domain_info$display_name %||% NA_character_,
          description = domain_info$description %||% NA_character_,
          works_count = domain_info$works_count %||% 0L
        )
      }
    }) |>
    distinct(domain_id, .keep_all = TRUE) |>
    mutate(
      created_date = Sys.time(),
      updated_date = Sys.time()
    )
  
  return(domains)
}

# Function to extract field data from OpenAlex response
extract_fields <- function(topics_data) {
  fields <- topics_data |>
    map_dfr(~ {
      field_info <- .x$field
      domain_info <- .x$domain
      if (!is.null(field_info)) {
        tibble(
          field_id = if (!is.null(.x$field)) sub("https://openalex.org/fields/", "", .x$field$id) else NA_character_,
          display_name = field_info$display_name %||% NA_character_,
          description = field_info$description %||% NA_character_,
          works_count = field_info$works_count %||% 0L,
          domain_id = if (!is.null(domain_info)) sub("https://openalex.org/domains/", "", domain_info$id) else NA_character_
        )
      }
    }) |>
    distinct(field_id, .keep_all = TRUE) |>
    mutate(
      created_date = Sys.time(),
      updated_date = Sys.time()
    )
  
  return(fields)
}

# Function to extract subfield data from OpenAlex response
extract_subfields <- function(topics_data) {
  subfields <- topics_data |>
    map_dfr(~ {
      subfield_info <- .x$subfield
      field_info <- .x$field
      if (!is.null(subfield_info)) {
        tibble(
          subfield_id = if (!is.null(.x$subfield)) sub("https://openalex.org/subfields/", "", .x$subfield$id) else NA_character_,
          display_name = subfield_info$display_name %||% NA_character_,
          description = subfield_info$description %||% NA_character_,
          works_count = subfield_info$works_count %||% 0L,
          field_id = if (!is.null(field_info)) sub("https://openalex.org/fields/", "",field_info$id) else NA_character_
        )
      }
    }) |>
    distinct(subfield_id, .keep_all = TRUE) |>
    mutate(
      created_date = Sys.time(),
      updated_date = Sys.time()
    )
  
  return(subfields)
}

# Function to extract topics data from OpenAlex response
extract_topics <- function(topics_data) {
  topics <- topics_data |>
    map_dfr(~ {
    #   keywords_json <- if (!is.null(.x$keywords) && length(.x$keywords) > 0) {
        # keywords_clean <- purrr::map(.x$keywords, function(kw) {
        #   kw$id <- sub("https://openalex.org/keywords/", "", kw$id)
        #   kw
        # })
        # jsonlite::toJSON(keywords_clean, auto_unbox = TRUE)
    #   } else {
    #     NA_character_
    #   }
      tibble(
        topic_id = sub("https://openalex.org/", "", .x$id),
        display_name = .x$display_name %||% NA_character_,
        description = .x$description %||% NA_character_,
        # keywords = keywords_json,
        works_count = .x$works_count %||% 0L,
        cited_by_count = .x$cited_by_count %||% 0L,
        subfield_id = if (!is.null(.x$subfield)) sub("https://openalex.org/subfields/", "",.x$subfield$id) else NA_character_
      )
    }) |>
    mutate(
      created_date = Sys.time(),
      updated_date = Sys.time()
    )
  return(topics)
}

# Main function to populate the database
populate_topics_hierarchy <- function(db_path = "database.sqlite", force_refresh = FALSE) {
  # Connect to database
  con <- dbConnect(RSQLite::SQLite(), db_path)
  
  # Create tables with updated schema to match OpenAlex structure
  create_table_safe(con, "domains", "
  CREATE TABLE domains (
      domain_id TEXT PRIMARY KEY,
      display_name TEXT NOT NULL,
      description TEXT,
      works_count INTEGER DEFAULT 0,
      created_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
      updated_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP
  )")
  
  create_table_safe(con, "fields", "
  CREATE TABLE fields (
      field_id TEXT PRIMARY KEY,
      display_name TEXT NOT NULL,
      description TEXT,
      works_count INTEGER DEFAULT 0,
      domain_id TEXT,
      created_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
      updated_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
      FOREIGN KEY (domain_id) REFERENCES domains(domain_id)
  )")
  
  create_table_safe(con, "subfields", "
  CREATE TABLE subfields (
      subfield_id TEXT PRIMARY KEY,
      display_name TEXT NOT NULL,
      description TEXT,
      works_count INTEGER DEFAULT 0,
      field_id TEXT,
      created_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
      updated_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
      FOREIGN KEY (field_id) REFERENCES fields(field_id)
  )")
  
  create_table_safe(con, "topics", "
  CREATE TABLE topics (
      topic_id TEXT PRIMARY KEY,
      display_name TEXT NOT NULL,
      description TEXT,
      works_count INTEGER DEFAULT 0,
      cited_by_count INTEGER DEFAULT 0,
      subfield_id TEXT,
      created_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
      updated_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
      FOREIGN KEY (subfield_id) REFERENCES subfields(subfield_id)
  )")
  
  tryCatch({
    # Fetch all topics data from OpenAlex
    cat("Fetching topics data from OpenAlex API...\n")
    topics_data <- fetch_openalex_data_cached("topics", 
                                          params = list(sort = "works_count:desc"),
                                          force_refresh = force_refresh)
    
    cat("Fetched", length(topics_data), "topics\n")
    
    # Extract hierarchical data
    cat("Extracting domains...\n")
    domains <- extract_domains(topics_data)
    cat("Found", nrow(domains), "unique domains\n")
    
    cat("Extracting fields...\n")
    fields <- extract_fields(topics_data)
    cat("Found", nrow(fields), "unique fields\n")
    
    cat("Extracting subfields...\n")
    subfields <- extract_subfields(topics_data)
    cat("Found", nrow(subfields), "unique subfields\n")
    
    cat("Extracting topics...\n")
    topics <- extract_topics(topics_data)
    cat("Found", nrow(topics), "topics\n")
    
    # Insert data in hierarchical order (parents before children)
    cat("Inserting domains...\n")
    if (nrow(domains) > 0) {
      dbWriteTable(con, "domains", domains, overwrite = TRUE)
    }
    
    cat("Inserting fields...\n")
    if (nrow(fields) > 0) {
      dbWriteTable(con, "fields", fields, overwrite = TRUE)
    }
    
    cat("Inserting subfields...\n")
    if (nrow(subfields) > 0) {
      dbWriteTable(con, "subfields", subfields, overwrite = TRUE)
    }
    
    cat("Inserting topics...\n")
    if (nrow(topics) > 0) {
      dbWriteTable(con, "topics", topics, overwrite = TRUE)
    }
    
    # Verify data integrity
    cat("\nData summary:\n")
    cat("Domains:", dbGetQuery(con, "SELECT COUNT(*) as count FROM domains")$count, "\n")
    cat("Fields:", dbGetQuery(con, "SELECT COUNT(*) as count FROM fields")$count, "\n")
    cat("Subfields:", dbGetQuery(con, "SELECT COUNT(*) as count FROM subfields")$count, "\n")
    cat("Topics:", dbGetQuery(con, "SELECT COUNT(*) as count FROM topics")$count, "\n")
    
    # Check for orphaned records
    orphaned_fields <- dbGetQuery(con, "
      SELECT COUNT(*) as count 
      FROM fields f 
      LEFT JOIN domains d ON f.domain_id = d.domain_id 
      WHERE f.domain_id IS NOT NULL AND d.domain_id IS NULL
    ")$count
    
    orphaned_subfields <- dbGetQuery(con, "
      SELECT COUNT(*) as count 
      FROM subfields s 
      LEFT JOIN fields f ON s.field_id = f.field_id 
      WHERE s.field_id IS NOT NULL AND f.field_id IS NULL
    ")$count
    
    orphaned_topics <- dbGetQuery(con, "
      SELECT COUNT(*) as count 
      FROM topics t 
      LEFT JOIN subfields s ON t.subfield_id = s.subfield_id 
      WHERE t.subfield_id IS NOT NULL AND s.subfield_id IS NULL
    ")$count
    
    if (orphaned_fields > 0 || orphaned_subfields > 0 || orphaned_topics > 0) {
      cat("WARNING: Found orphaned records:\n")
      cat("- Orphaned fields:", orphaned_fields, "\n")
      cat("- Orphaned subfields:", orphaned_subfields, "\n")
      cat("- Orphaned topics:", orphaned_topics, "\n")
    } else {
      cat("✓ No orphaned records found\n")
    }
    
    cat("✓ Successfully populated topics hierarchy from OpenAlex\n")
    
  }, error = function(e) {
    cat("Error occurred:", e$message, "\n")
    stop(e)
  }, finally = {
    dbDisconnect(con)
  })
}

# Execute the population
# Set force_refresh = TRUE to re-download data from OpenAlex API
# Set force_refresh = FALSE (default) to use cached data if available
populate_topics_hierarchy(db_path = "openAlex_topics.sqlite",force_refresh = FALSE)

#From the database, export a CSV table of the topics hierarchy - domains, fields and subfields only- joined into a single table
#Join the tables on the domain_id, field_id and subfield_id
#The table should have the following columns: domain_id, domain_name, field_id, field_name, subfield_id, subfield_name, subfield_works_count
#The table should be sorted by domain_name, field_name, subfield_name
db_path = "openAlex_topics.sqlite"
con <- dbConnect(RSQLite::SQLite(), db_path)
domains <- dbGetQuery(con, "SELECT * FROM domains") |>
  rename(domain_id = domain_id, domain_name = display_name, domain_description = description, domain_works_count = works_count)
fields <- dbGetQuery(con, "SELECT * FROM fields") |>
  rename(field_id = field_id, field_name = display_name, field_description = description, field_works_count = works_count)
subfields <- dbGetQuery(con, "SELECT * FROM subfields") |>
  rename(subfield_id = subfield_id, subfield_name = display_name, subfield_description = description, subfield_works_count = works_count)
#Join the tables on the domain_id, field_id and subfield_id
topics_hierarchy <- domains |>
  left_join(fields, by = "domain_id") |>
  left_join(subfields, by = "field_id") |>
  select(domain_name, field_name, subfield_name, domain_id, field_id, subfield_id) |>
  arrange(domain_name, field_name, subfield_name)

library(googlesheets4)
write_sheet(topics_hierarchy, ss = '1WRlXkr4LzLiv6pka8cnPz0tlmid8dbsR9VUo_u-Lh-w' , sheet = 'OpenAlex_subfields')




dbDisconnect(con)


# Optional: Function to query the hierarchy for testing
query_topic_hierarchy <- function(topic_name = NULL, db_path = "openAlex_topics.sqlite") {
  con <- dbConnect(RSQLite::SQLite(), db_path)
  
  query <- "
  SELECT 
    t.topic_id,
    t.display_name as topic_name,
    t.description as topic_description,
    t.works_count as topic_works_count,
    t.cited_by_count,
    s.display_name as subfield_name,
    f.display_name as field_name,
    d.display_name as domain_name
  FROM topics t
  LEFT JOIN subfields s ON t.subfield_id = s.subfield_id
  LEFT JOIN fields f ON s.field_id = f.field_id
  LEFT JOIN domains d ON f.domain_id = d.domain_id
  "
  
  if (!is.null(topic_name)) {
    query <- paste0(query, "WHERE t.display_name LIKE '%", topic_name, "%'")
  }
  
  query <- paste0(query, " ORDER BY t.works_count DESC LIMIT 10")
  
  result <- dbGetQuery(con, query)
  dbDisconnect(con)
  
  return(result)
}

# Test the hierarchy query
cat("\nTop 10 topics by works count:\n")
print(query_topic_hierarchy())

#Check if subfield_id has had the URL removed
db_path = "openAlex_topics.sqlite"
con <- dbConnect(RSQLite::SQLite(), db_path)
#Summarise this database and provide the schema
dbListTables(con)
dbGetQuery(con, "SELECT * FROM subfields LIMIT 3")
dbGetQuery(con, "SELECT * FROM fields LIMIT 3")
dbGetQuery(con, "SELECT * FROM domains LIMIT 3")
dbGetQuery(con, "SELECT * FROM topics LIMIT 3")
dbDisconnect(con)
