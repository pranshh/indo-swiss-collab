#This file searches and imports data from OpenAlex.

rm(list = ls())
source('core_utilities.R')
using('httr','stringr','dplyr','tidyr','tidyRSS','jsonlite','lubridate','ggplot2','readxl','readr','purrr','knitr','tibble')
using('data.table','arrow')

# Define the query parameters as a list.
# 'httr' will correctly format these into a URL query string.
# This is where we specify the AND condition for country codes.
library(openalexR)

# Helper function to remove the OpenAlex URL prefix from IDs

clean_id <- function(id) {
  str_remove_all(id, "(https://openalex\\.org/)|(https://ror\\.org/)|(https://doi\\.org/)|(https://orcid\\.org/)")
}

# Fast clean_id on JSON strings
clean_affiliations_json_fast <- function(json_str) {
  if (is.na(json_str)) return(NA_character_)
  
  # Use string replacement directly on JSON - much faster
  json_str %>%
    # Clean URLs in id, ror, lineage fields
    str_replace_all('"id":"https://openalex\\.org/', '"inst_id":"') %>%
    str_replace_all('"ror":"https://ror\\.org/', '"ror":"') %>%
    str_replace_all('"lineage":"https://openalex\\.org/', '"lineage":"') %>%
    # Remove any remaining id field and replace with inst_id if needed
    str_replace_all('"id":', '"inst_id":')
}

clean_topics_json_fast <- function(json_str) {
  if (is.na(json_str)) return(NA_character_)
  
  # Clean URLs in topics JSON
  json_str %>%
    str_replace_all('https://openalex\\.org/', '') %>%
    str_replace_all('https://doi\\.org/', '')
}


# Getting the Data from OpenAlex ------------------------------------------

get_openalex_data = function(start.date = NULL, end.date = NULL, dois = NULL) {
  # Validate input parameters
  if (is.null(start.date) && is.null(end.date) && is.null(dois)) {
    stop("Must provide either date range (start.date and end.date) or DOI list (dois)")
  }
  
  if (!is.null(start.date) && !is.null(end.date) && !is.null(dois)) {
    stop("Cannot provide both date range and DOI list - choose one mode")
  }
  
  if ((!is.null(start.date) && is.null(end.date)) || (is.null(start.date) && !is.null(end.date))) {
    stop("Both start.date and end.date must be provided for date range mode")
  }
  
  # Define common select fields
  select_fields <- "id,title,display_name,authorships,doi,publication_date,publication_year,primary_location,sources,institution_assertions,countries_distinct_count,institutions_distinct_count,is_authors_truncated,primary_topic,cited_by_count,ids,type,topics,keywords,is_retracted,grants,abstract_inverted_index"
  
  # Mode 1: Date range mode (original functionality)
  if (!is.null(start.date) && !is.null(end.date)) {
    print("Mode: Date range query")
    query_params <- paste0("https://api.openalex.org/works?",
                           "filter=",
                           "authorships.institutions.country_code:in,",
                           "authorships.institutions.country_code:ch,",
                           "from_publication_date:",start.date,',',
                           "to_publication_date:",end.date,
                           "&select=",select_fields)
    print("Requesting URL from OpenAlex API...")
    response <- oa_request(query_url = URLencode(query_params), mailto = 'siddharth.bharath@protonmail.com')
    publications_df <- oa2df(data = response, entity = 'works')
    print(paste('Downloaded', nrow(publications_df), 'works from OpenAlex in this period.'))
  } 
  
  # Mode 2: DOI list mode
  else if (!is.null(dois)) {
    print("Mode: DOI list query")
    # Split into batches of 50
    batch_size <- 50
    doi_batches <- split(dois, ceiling(seq_along(dois) / batch_size))
    select_fields_vector <- unlist(str_split(select_fields, ','))
    
    # Fetch in batches and row-bind results
    publications_df <- purrr::map_dfr(doi_batches, function(batch) {
      cat("Processing batch with", length(batch), "DOIs...\n")
      
      # Query OpenAlex for these DOIs
      out <- tryCatch({
        oa_fetch(
          entity = "works", 
          doi = batch, 
          mailto = 'siddharth.bharath@protonmail.com',
          options = list(select = select_fields_vector)
        )
      }, error = function(e) {
        warning("Failed batch: ", paste(head(batch, 3), collapse = ", "), "... → ", e$message)
        return(tibble())  # return empty tibble on error
      })
      
      Sys.sleep(0.2)  # small pause to respect API rate limits
      return(out)
    })
    
    print(paste('Downloaded', nrow(publications_df), 'works from OpenAlex using DOI list.'))
  }
  
  # Common processing for both modes: handle truncated authorships
  if (nrow(publications_df) > 0) {
    publications_df <- mutate(publications_df, 
                              rownum = row_number(), 
                              id = clean_id(id), 
                              doi = clean_id(doi), 
                              source_id = clean_id(source_id), 
                              host_organization = clean_id(host_organization))
    
    # Find publications with exactly 100 authors (indicating truncation)
    auth100 <- publications_df %>% 
      filter(map_int(authorships, nrow) == 100) %>% 
      pull(rownum)
    
    if(length(auth100) > 0) {
      print(paste(length(auth100), 'of these publications have more than 100 authors. Getting their details separately from OpenAlex.'))
      
      for(i in auth100) {
        query_params <- paste0("https://api.openalex.org/works/",clean_id(publications_df$id[i]),"?select=id,authorships")
        response <- oa_request(query_url = query_params, mailto = 'siddharth.bharath@protonmail.com')
        x <- oa2df(data = response, entity = 'works')$authorships
        publications_df$authorships[i] <- x
        rm(x, response)
        if(i %% 3 == 0) print(paste("Processed", i, "of", length(auth100), "truncated records"))
      }
    }
    
    return(publications_df %>% select(-rownum))
  } else {
    warning("No publications found")
    return(tibble())
  }

}
# Function to save publications data to parquet format
save_publications_parquet <- function(publications_df, year_range_label) {
  
  # Create directory if it doesn't exist
  # dir.create("Data/publications_oa_parquet", showWarnings = FALSE, recursive = TRUE)
  
  # Define file paths
  main_file <- file.path("Data/publications_oa_parquet", paste0("publications_main_", year_range_label, ".parquet"))
  authorships_file <- file.path("Data/publications_oa_parquet", paste0("authorships_", year_range_label, ".parquet"))
  
  cat("Processing", nrow(publications_df), "publications for", year_range_label, "...\n")
  
  # 1. Extract main publication data (excluding authorships)
  main_data <- publications_df %>%
    select(-authorships) %>%
    # Convert remaining list columns to JSON strings for storage
    mutate(
      ids = map_chr(ids, ~ ifelse(is.null(.x), NA_character_, jsonlite::toJSON(.x, auto_unbox = TRUE))),
      topics = map_chr(topics, ~ ifelse(is.null(.x), NA_character_, jsonlite::toJSON(.x, auto_unbox = TRUE))),
      keywords = map_chr(keywords, ~ ifelse(is.null(.x), NA_character_, jsonlite::toJSON(.x, auto_unbox = TRUE))),
      grants = map_chr(grants, ~ ifelse(is.null(.x) || (length(.x) == 1 && is.na(.x)), NA_character_, jsonlite::toJSON(.x, auto_unbox = TRUE)))
    ) %>% rename(work_id = id)
  
  # Save main publication data
  write_parquet(main_data, main_file)
  cat("✓ Saved main data:", file.size(main_file) / 1024^2, "MB\n")
  
  # 2. Extract and save authorships data separately
  authorships_data <- publications_df %>%
    select(work_id = id, authorships) %>%
    # Filter out rows where authorships is NULL or empty
    filter(!map_lgl(authorships, ~ is.null(.x) || length(.x) == 0)) %>%
    # Unnest the authorships
    unnest(authorships) %>%
    # clean up ids in the authorships block
    mutate(author_id = clean_id(id), orcid = clean_id(orcid)) %>%
    select(-id) %>%
    # mutate(affiliations = map(affiliations, function(affil_df) {
    #   if (is.null(affil_df) || nrow(affil_df) == 0) {
    #     return(NULL)
    #   }
    #   affil_df %>%
    #     mutate(
    #       # Clean IDs and rename id to inst_id
    #       inst_id = clean_id(id),
    #       ror = clean_id(ror),
    #       lineage = clean_id(lineage)
    #     ) %>%
    #     select(-id) %>%  # Remove original id column
    #     select(inst_id, everything())  # Put inst_id first
    # }),) %>%
    # Convert the nested affiliations list-column to JSON string
    mutate(
      affiliations = map_chr(affiliations, ~ ifelse(is.null(.x) || length(.x) == 0, 
                                                    NA_character_, 
                                                    jsonlite::toJSON(.x, auto_unbox = TRUE)))
    )
  
  # Save authorships data
  write_parquet(authorships_data, authorships_file)
  cat("✓ Saved authorships data:", file.size(authorships_file) / 1024^2, "MB\n")
  
  # Print summary
  cat("Summary for", year_range_label, ":\n")
  cat("  - Publications:", nrow(publications_df), "\n")
  cat("  - Total authorships:", nrow(authorships_data), "\n")
  cat("  - Files saved in: Data/publications_oa_parquet/\n\n")
  
  # Return summary information
  return(list(
    year_range = year_range_label,
    n_publications = nrow(publications_df),
    n_authorships = nrow(authorships_data),
    main_file_size_mb = round(file.size(main_file) / 1024^2, 2),
    authorships_file_size_mb = round(file.size(authorships_file) / 1024^2, 2)
  ))
}

dateranges = data.frame(start.date = c('2000-01-01','2008-01-01','2013-01-01','2017-01-01','2020-01-01','2022-01-01','2024-01-01'),
                        end.date =  c( '2007-12-31','2012-12-31','2016-12-31','2019-12-31','2021-12-31','2023-12-31','2024-12-31'))

# for(i in 1:nrow(dateranges)) {
#   publications_df = get_openalex_data(start.date = dateranges$start.date[i],end.date = dateranges$end.date[i])
#   save_publications_parquet(publications_df, year_range_label = paste(dateranges$start.date[i],dateranges$end.date[i],sep= '_'))
# }



# Process the publications data -------------------------------------------

read_publications_dataset <- function() {
  
  # Get all main publication files
  main_files <- list.files("Data/publications_oa_parquet", 
                           pattern = "publications_main_.*\\.parquet$", 
                           full.names = TRUE)
  
  # Get all authorships files
  auth_files <- list.files("Data/publications_oa_parquet", 
                           pattern = "authorships_.*\\.parquet$", 
                           full.names = TRUE)
  
  cat("Found", length(main_files), "main publication files\n")
  cat("Found", length(auth_files), "authorships files\n")
  
  # Read and combine main data
  main_data_list <- map(main_files, read_parquet)
  main_data <- bind_rows(main_data_list)
  
  # Read and combine authorships data
  auth_data_list <- map(auth_files, read_parquet)
  auth_data <- bind_rows(auth_data_list)
  
  cat("Total publications:", nrow(main_data), "\n")
  cat("Total authorships:", nrow(auth_data), "\n")
  
  return(list(main_data = main_data, auth_data = auth_data))
}

# Read the data
dataset <- read_publications_dataset()
main_data <- dataset$main_data
auth_data <- dataset$auth_data

oa_dois <- main_data %>%
  filter(!is.na(doi)) %>%
  distinct(doi) %>%
  pull(doi) %>% clean_id() %>% tolower()


# Adding in papers from Web of Science and Scopus -------------------------

#Now OpenAlex will miss collaborative publications where the author from India or Switzerland is in the list later than 100.
#So quickly load in the WoS and Scopus data, check all the DOIs that are present there, and not present in openAlex data.
paper.details.ws = readRDS(file = 'Data/publication_details.RData')
ws_dois = tolower(paper.details.ws$doi) #%>% str_c('https://doi.org/')
missing_dois = setdiff(ws_dois,oa_dois)

# TODO Now check if these doi entries are in openAlex
missing_dois = paper.details.ws %>% filter(tolower(doi) %in% missing_dois) %>% select(doi,nAuthors)
rm(paper.details.ws)
#First get all those that are with less than 100 authors

dois = missing_dois %>% filter(nAuthors < 100) %>% pull(doi)

# split into batches of 10
batch_size <- 50
doi_batches <- split(dois, ceiling(seq_along(dois) / batch_size))

select_fields = "id,title,display_name,authorships,doi,publication_date,publication_year,primary_location,sources,institution_assertions,countries_distinct_count,institutions_distinct_count,is_authors_truncated,primary_topic,cited_by_count,ids,type,topics,keywords,is_retracted,grants,abstract_inverted_index"
select_fields <- unlist(str_split(select_fields, ','))

# Fetch in batches and row-bind results
all_works <- purrr::map_dfr(doi_batches, function(batch) {
  cat("Processing batch with", length(batch), "DOIs...\n")
  
  # Query OpenAlex for these DOIs
  out <- tryCatch({
    oa_fetch(
      entity = "works", 
      doi = batch, 
      mailto = 'siddharth.bharath@protonmail.com',
      options = list(select = select_fields)
    )
  }, error = function(e) {
    warning("Failed batch: ", paste(head(batch, 3), collapse = ", "), "... → ", e$message)
    return(tibble())  # return empty tibble on error
  })
  
  Sys.sleep(0.2)  # small pause to respect API rate limits
  return(out)
})


save_publications_parquet(all_works %>% filter(map_int(authorships, nrow) < 100),
                          'from_WoS-Scopus_1')
#Now get the ones that have more than 100 authors

dois = missing_dois %>% filter(nAuthors >= 100) %>% pull(doi)

# split into batches of 50
batch_size  <- 50
doi_batches <- split(dois, ceiling(seq_along(dois) / batch_size))

# fetch only id + doi for each batch, then bind into one tibble
work_ids_tbl <- purrr::map_dfr(doi_batches, function(batch) {
  # small pause to be polite to the API
  Sys.sleep(0.1)
  
  oa_fetch(
    entity  = "works",
    doi     = batch,
    options = list(select = "doi,id")
  ) %>%
    select(doi, id)
})

#check all_works - if any of the entries have exactly 100 authors, then add them to work_ids_tbl

nauth = all_works %>% 
  filter(map_int(authorships, nrow) == 100) %>% select(id,doi)
work_ids_tbl = bind_rows(work_ids_tbl,nauth)
work_ids_tbl$id = clean_id(work_ids_tbl$id)
big_works = tibble()

library(progress)
pb <- progress_bar$new(
  format = "[:bar] :percent (:current/:total) ETA: :eta",
  total = nrow(work_ids_tbl),
  clear = FALSE
)

for(i in 351:nrow(work_ids_tbl)) {
  pb$tick()
  query_params <- paste0("https://api.openalex.org/works/",work_ids_tbl$id[i],"?mailto=siddharth.bharath@protonmail.com&select=id,title,display_name,authorships,doi,publication_date,publication_year,primary_location,sources,institution_assertions,countries_distinct_count,institutions_distinct_count,is_authors_truncated,primary_topic,cited_by_count,ids,type,topics,keywords,is_retracted,grants,abstract_inverted_index")
  response <- oa_request(query_url = query_params)
  x = oa2df(data = response, entity = 'works')
  big_works = bind_rows(big_works,x)
  rm(x,response)
  if(i%%350==0) {
    save_publications_parquet(big_works,
                              paste0('from_WoS-Scopus_3-',floor(i/350)))
    big_works = tibble()
  }
}
save_publications_parquet(big_works,
                          paste0('from_WoS-Scopus_3-',ceiling(i/350)))


# 
# saveRDS(all_works, 'Data/Additional_openAlex.rdata')
# 
# publications_df = bind_rows(publications_df,all_works) %>%
#   group_by(id) %>% slice_tail(n = 1) %>%
#   select(-concepts,-apc,-referenced_works,-related_works,-referenced_works_count, -landing_page_url,-counts_by_year)
# 
# # big_works = readRDS('Data/Additional_openAlex_big.rdata')
# 
# saveRDS(publications_df, 
#         'Data/openAlex_df_2000-2024.rdata')

#Now clean the data gotten from Pranshu

paper.details.oa = read_parquet('Data/publication_combined_2000_2024.parquet')

paper.details.oa = paper.details.oa %>% 
  mutate(work_id = clean_id(work_id),doi = clean_id(doi),
         source_id = clean_id(source_id), 
         host_organization = clean_id(host_organization),
         ids = clean_id(ids),
         topics = clean_id(topics)
  )

write_parquet(paper.details.oa, 'Data/publication_combined_2000_2024.parquet')

authorship.oa = read_parquet('Data/authorships_combined_2000_2024.parquet')

str(authorship.oa)



# Organise and save OpenAlex data --------------------------------------------

library(stringr)
library(data.table)  # For faster processing

# Read all data efficiently
read_all_data <- function() {
  main_files <- list.files("Data/publications_oa_parquet", 
                           pattern = "publications_main_.*\\.parquet$", 
                           full.names = TRUE)
  auth_files <- list.files("Data/publications_oa_parquet", 
                           pattern = "authorships_.*\\.parquet$", 
                           full.names = TRUE)
  
  main_data <- map_dfr(main_files, read_parquet)
  auth_data <- map_dfr(auth_files, read_parquet)
  
  return(list(main_data = main_data, auth_data = auth_data))
}

# 1. COMPREHENSIVE DATA QUALITY CHECKS
run_data_quality_checks <- function() {
  
  cat("=== READING DATA ===\n")
  dataset <- read_all_data()
  main_data <- dataset$main_data
  auth_data <- dataset$auth_data
  
  cat("Main data:", nrow(main_data), "rows\n")
  cat("Auth data:", nrow(auth_data), "rows\n\n")
  
  cat("=== PUBLICATIONS WITH 0 AUTHORSHIP DATA ===\n")
  
  # Find publications with no authorship data
  pubs_with_authors <- unique(auth_data$publication_id)
  pubs_without_authors <- main_data$id[!main_data$id %in% pubs_with_authors]
  
  cat("Publications without authors:", length(pubs_without_authors), "\n")
  cat("Percentage without authors:", round(length(pubs_without_authors)/nrow(main_data)*100, 2), "%\n\n")
  
  if (length(pubs_without_authors) > 0) {
    cat("Sample publications without authors:\n")
    main_data %>% 
      filter(id %in% head(pubs_without_authors, 5)) %>%
      select(id, title, publication_year) %>%
      print()
  }
  
  cat("\n=== AFFILIATIONS DATA STRUCTURE CHECK ===\n")
  
  # Sample affiliations to check structure
  sample_affiliations <- auth_data %>% 
    filter(!is.na(affiliations)) %>% 
    slice_head(n = 10) %>%
    pull(affiliations)
  
  # Check first few affiliations structures
  for(i in 1:min(3, length(sample_affiliations))) {
    cat("Sample", i, "affiliations structure:\n")
    parsed <- fromJSON(sample_affiliations[i])
    cat("Columns:", paste(names(parsed), collapse = ", "), "\n")
    if ("id" %in% names(parsed)) {
      cat("⚠️  Found 'id' column - needs renaming to 'inst_id'\n")
    }
    if ("inst_id" %in% names(parsed)) {
      cat("✓ Found 'inst_id' column\n")
    }
    cat("\n")
  }
  
  cat("=== TOPICS DATA STRUCTURE CHECK ===\n")
  
  # Check topics structure
  sample_topics <- main_data %>% 
    filter(!is.na(topics)) %>% 
    slice_head(n = 3) %>%
    pull(topics)
  
  for(i in 1:min(2, length(sample_topics))) {
    cat("Sample", i, "topics structure:\n")
    parsed <- fromJSON(sample_topics[i])
    cat("Columns:", paste(names(parsed), collapse = ", "), "\n")
    if (any(str_detect(parsed$id, "https://"))) {
      cat("⚠️  Found URLs in topics IDs - need cleaning\n")
    }
    cat("\n")
  }
  
  return(list(
    pubs_without_authors = pubs_without_authors,
    total_pubs = nrow(main_data),
    total_auths = nrow(auth_data)
  ))
}


# 3. OPTIMIZED PROCESSING FUNCTION
process_data_optimized <- function(batch_size = 50000) {
  
  cat("=== READING DATA FOR PROCESSING ===\n")
  dataset <- read_all_data()
  main_data <- dataset$main_data
  auth_data <- dataset$auth_data
  
  cat("=== PROCESSING TOPICS (MAIN DATA) ===\n")
  
  # Process topics in main data using fast string operations
  main_data_clean <- main_data %>%
    mutate(
      topics = map_chr(topics, clean_topics_json_fast),
      # Also clean other JSON fields if needed
      ids = map_chr(ids, clean_topics_json_fast),  # Remove URLs from IDs
      keywords = keywords  # Keep as is for now
    )
  
  cat("✓ Topics cleaned\n")
  
  cat("=== PROCESSING AFFILIATIONS (AUTH DATA) ===\n")
  
  # Convert to data.table for faster processing
  auth_dt <- as.data.table(auth_data)
  
  # Process in batches to manage memory
  n_batches <- ceiling(nrow(auth_dt) / batch_size)
  cat("Processing", nrow(auth_dt), "rows in", n_batches, "batches\n")
  
  processed_batches <- list()
  
  for(i in 1:n_batches) {
    start_idx <- (i-1) * batch_size + 1
    end_idx <- min(i * batch_size, nrow(auth_dt))
    
    cat("Batch", i, "of", n_batches, "(rows", start_idx, "to", end_idx, ")\n")
    
    batch_data <- auth_dt[start_idx:end_idx]
    
    # Fast JSON processing
    batch_data[, affiliations_clean := clean_affiliations_json_fast(affiliations)]
    
    processed_batches[[i]] <- as_tibble(batch_data)
  }
  
  auth_data_clean <- bind_rows(processed_batches)
  
  cat("✓ Affiliations cleaned\n")
  
  return(list(
    main_data = main_data_clean,
    auth_data = auth_data_clean
  ))
}

# 4. SAVE CLEANED DATA
save_cleaned_data <- function(cleaned_data, suffix = "cleaned") {
  
  main_data <- cleaned_data$main_data
  auth_data <- cleaned_data$auth_data
  
  # Create cleaned directory
  dir.create("Data/publications_oa_parquet_cleaned", showWarnings = FALSE, recursive = TRUE)
  
  # Save cleaned main data
  main_file <- file.path("Data/publications_oa_parquet_cleaned", 
                         paste0("publications_main_", suffix, ".parquet"))
  write_parquet(main_data, main_file)
  
  # Save cleaned auth data  
  auth_file <- file.path("Data/publications_oa_parquet_cleaned", 
                         paste0("authorships_", suffix, ".parquet"))
  write_parquet(auth_data, auth_file)
  
  cat("✓ Cleaned data saved to:", dirname(main_file), "\n")
  cat("Main data size:", round(file.size(main_file) / 1024^2, 1), "MB\n")
  cat("Auth data size:", round(file.size(auth_file) / 1024^2, 1), "MB\n")
}

# 5. VALIDATION FUNCTION
validate_cleaned_data <- function() {
  
  # Read cleaned data
  main_file <- "Data/publications_oa_parquet_cleaned/publications_main_cleaned.parquet"
  auth_file <- "Data/publications_oa_parquet_cleaned/authorships_cleaned.parquet"
  
  if (!file.exists(main_file) || !file.exists(auth_file)) {
    cat("❌ Cleaned files not found. Run processing first.\n")
    return(FALSE)
  }
  
  main_data <- read_parquet(main_file)
  auth_data <- read_parquet(auth_file)
  
  cat("=== VALIDATION RESULTS ===\n")
  
  # Check topics cleaning
  sample_topics <- main_data %>% filter(!is.na(topics)) %>% slice_head(n=3) %>% pull(topics)
  topics_have_urls <- any(str_detect(sample_topics, "https://", na.rm = TRUE))
  cat("Topics still have URLs:", topics_have_urls, ifelse(topics_have_urls, "❌", "✓"), "\n")
  
  # Check affiliations cleaning
  sample_affils <- auth_data %>% filter(!is.na(affiliations_clean)) %>% slice_head(n=3) %>% pull(affiliations_clean)
  affils_have_urls <- any(str_detect(sample_affils, "https://openalex\\.org/", na.rm = TRUE))
  cat("Affiliations still have URLs:", affils_have_urls, ifelse(affils_have_urls, "❌", "✓"), "\n")
  
  # Check for inst_id vs id
  sample_parsed <- fromJSON(sample_affils[1])
  has_inst_id <- "inst_id" %in% names(sample_parsed)
  has_old_id <- "id" %in% names(sample_parsed)
  cat("Affiliations have inst_id:", has_inst_id, ifelse(has_inst_id, "✓", "❌"), "\n")
  cat("Affiliations still have 'id':", has_old_id, ifelse(has_old_id, "❌", "✓"), "\n")
  
  return(TRUE)
}

cat("=== RUNNING DATA QUALITY CHECKS ===\n")
quality_results <- run_data_quality_checks()

cat("\n=== PROCESSING DATA WITH OPTIMIZATIONS ===\n")
cleaned_data <- process_data_optimized(batch_size = 10000)  # Adjust batch size based on memory

cat("\n=== TO SAVE CLEANED DATA, RUN ===\n")
save_cleaned_data(cleaned_data)

cat("\n=== TO VALIDATE CLEANED DATA, RUN ===\n")
validate_cleaned_data()
      


# Update author summaries -----------------------------------

paper.details = read_parquet("Data/publications_full_dataset_2000-2024.parquet")
authors_processed = read_parquet("Data/authors_processed_flat.parquet")
authors_summ = read_parquet("Data/authors_summary_with_lists.parquet")

create_author_summary_fast <- function(authors_processed) {
  
  print("Starting fast author summary creation...")
  start_time <- Sys.time()
  
  # Convert to data.table if not already
  if (!is.data.table(authors_processed)) {
    setDT(authors_processed)
  }
  
  print("Step 1: Creating institution work counts...")
  step1_time <- Sys.time()
  
  # Step 1: Create institution-work mapping
  # Expand institutions for each author-work combination
  institutions_expanded <- authors_processed[
    !is.na(author_id) & !is.na(institutions_with_country),
    .(work_id, author_id, institutions = unlist(strsplit(institutions_with_country, "; "))),
    by = .(work_id, author_id)
  ][institutions != ""]
  
  # Count works per author-institution
  institution_counts <- institutions_expanded[, .(n_works = uniqueN(work_id)), by = .(author_id, institutions)]
  
  # Create nested structure for institutions
  institution_lists <- institution_counts[, .(
    institution_work_counts = list(.SD[order(-n_works)])
  ), by = author_id]
  
  print(paste("Step 1 completed in:", round(difftime(Sys.time(), step1_time, units = "secs"), 2), "seconds"))
  
  print("Step 2: Creating country work counts...")
  step2_time <- Sys.time()
  
  # Step 2: Create country-work mapping  
  # Expand countries for each author-work combination
  countries_expanded <- authors_processed[
    !is.na(author_id) & !is.na(author_countries),
    .(work_id, author_id, countries = unlist(strsplit(author_countries, ", "))),
    by = .(work_id, author_id)
  ][countries != ""]
  
  # Count works per author-country
  country_counts <- countries_expanded[, .(n_works = uniqueN(work_id)), by = .(author_id, countries)]
  
  # Create nested structure for countries
  country_lists <- country_counts[, .(
    country_work_counts = list(.SD[order(-n_works)])
  ), by = author_id]
  
  print(paste("Step 2 completed in:", round(difftime(Sys.time(), step2_time, units = "secs"), 2), "seconds"))
  
  print("Step 3: Determining collaboration status...")
  step3_time <- Sys.time()
  
  # Step 3: Determine collaboration status for each author
  # First, check for India-Switzerland collaboration per work (for Joint category)
  work_country_check <- authors_processed[
    !is.na(author_id) & !is.na(author_countries),
    .(
      has_IN = any(grepl("IN", author_countries)),
      has_CH = any(grepl("CH", author_countries))
    ),
    by = .(author_id, work_id)
  ]
  
  # Check if any work for each author has both IN and CH (Joint collaboration)
  india_swiss_joint <- work_country_check[, .(
    has_india_swiss_collab = any(has_IN & has_CH)
  ), by = author_id]
  
  # Check overall affiliation patterns for each author across all their works
  author_country_patterns <- countries_expanded[, .(
    has_ever_IN = any(countries == "IN"),
    has_ever_CH = any(countries == "CH")
  ), by = author_id]
  
  # Merge collaboration data to determine collab_status
  collaboration_data <- merge(india_swiss_joint, author_country_patterns, by = "author_id", all = TRUE)
  
  # Handle missing values (authors with no country data)
  collaboration_data[is.na(has_india_swiss_collab), has_india_swiss_collab := FALSE]
  collaboration_data[is.na(has_ever_IN), has_ever_IN := FALSE]
  collaboration_data[is.na(has_ever_CH), has_ever_CH := FALSE]
  
  # Create categorical collab_status variable
  collaboration_data[, collab_status := fcase(
    # Joint: has both IN and CH affiliations in same paper(s)
    has_india_swiss_collab == TRUE, "Joint",
    # Both: has had both IN and CH affiliations but never in same paper
    has_ever_IN == TRUE & has_ever_CH == TRUE & has_india_swiss_collab == FALSE, "Both",
    # IN: has had Indian affiliation but never Swiss
    has_ever_IN == TRUE & has_ever_CH == FALSE, "IN",
    # CH: has had Swiss affiliation but never Indian
    has_ever_IN == FALSE & has_ever_CH == TRUE, "CH",
    # None: neither Indian nor Swiss affiliations
    default = "None"
  )]
  
  print(paste("Step 3 completed in:", round(difftime(Sys.time(), step3_time, units = "secs"), 2), "seconds"))
  
  print("Step 4: Creating main author summary...")
  step4_time <- Sys.time()
  
  # Step 4: Main author summary with basic metrics
  authors_main <- authors_processed[!is.na(author_id), .(
    name = first(display_name, na_rm = TRUE),
    orcid = first(orcid, na_rm = TRUE),
    nWorks = uniqueN(work_id, na.rm = TRUE),
    total_institutions = {
      all_insts <- unlist(strsplit(institutions_with_country[!is.na(institutions_with_country)], "; "))
      length(unique(all_insts[all_insts != ""]))
    },
    total_countries = {
      all_countries <- unlist(strsplit(author_countries[!is.na(author_countries)], ", "))
      length(unique(all_countries[all_countries != ""]))
    },
    n_corresponding_works = sum(is_corresponding, na.rm = TRUE)
  ), by = author_id]
  
  print(paste("Step 4 completed in:", round(difftime(Sys.time(), step4_time, units = "secs"), 2), "seconds"))
  
  print("Step 5: Merging all components...")
  step5_time <- Sys.time()
  
  # Step 5: Merge all components
  # Start with main summary
  final_summary <- authors_main
  
  # Add institution lists
  final_summary <- merge(final_summary, institution_lists, by = "author_id", all.x = TRUE)
  
  # Add country lists  
  final_summary <- merge(final_summary, country_lists, by = "author_id", all.x = TRUE)
  
  # Add collaboration status (categorical variable)
  final_summary <- merge(final_summary, collaboration_data[, .(author_id, collab_status)], 
                         by = "author_id", all.x = TRUE)
  
  # Fill missing collaboration status with "None"
  final_summary[is.na(collab_status), collab_status := "None"]
  
  # Handle missing list columns
  final_summary[is.na(institution_work_counts), institution_work_counts := list(list(data.table(institutions = character(0), n_works = integer(0))))]
  final_summary[is.na(country_work_counts), country_work_counts := list(list(data.table(countries = character(0), n_works = integer(0))))]
  
  # Order by number of works
  setorder(final_summary, -nWorks)
  
  print(paste("Step 5 completed in:", round(difftime(Sys.time(), step5_time, units = "secs"), 2), "seconds"))
  
  # Print summary of collaboration status distribution
  print("Collaboration status distribution:")
  print(final_summary[, .N, by = collab_status][order(-N)])
  
  end_time <- Sys.time()
  print(paste("Total processing time:", round(difftime(end_time, start_time, units = "secs"), 2), "seconds"))
  
  return(final_summary)
}

author_summ = create_author_summary_fast(authors_processed)

write_parquet(author_summ, "Data/authors_summary_with_lists.parquet")

authors_summary_in_ch = author_summ[collab_status %in% c('CH','IN','Joint','Both')]
write_parquet(authors_summary_in_ch, "Data/authors_summary_in_ch.parquet")
