#This file interfaces with the OpenAlex API and database.

rm(list = ls())
source('core_utilities.R')
using('httr','stringr','dplyr','tidyr','tidyRSS','jsonlite','lubridate','ggplot2','readxl','readr','purrr','knitr','tibble')
using('countries','openalexR')



# Get the data ------------------------------------------------------------

# --- 1. SETUP ---
# Install packages if you haven't already
# install.packages("httr")
# install.packages("jsonlite")
# install.packages("dplyr")
# install.packages("purrr")
# install.packages("tidyr")

# Define the base URL for the 'works' endpoint
base_url <- "https://api.openalex.org/works"

# Define the query parameters as a list.
# 'httr' will correctly format these into a URL query string.
# This is where we specify the AND condition for country codes.
start.date = '2020-01-01'
end.date = '2024-12-31'

query_params <- paste0("https://api.openalex.org/works?filter=",
                       "authorships.institutions.country_code:in,",
                  "authorships.institutions.country_code:ch,",
                  "from_publication_date:",start.date,',',
                  "to_publication_date:",end.date)

# --- 3. EXECUTE THE REQUEST AND GET THE RESPONSE ---

# print("Requesting URL from OpenAlex API...")
# response <- oa_request(query_url = query_params)
# 
# publications_df = oa2df(data = response, entity = 'works')
# 
# saveRDS(publications_df,paste0('OA_',start.date,'_',end.date,'.rdata'))


# Process the publications data -------------------------------------------

files = list.files(pattern = '^OA_.*.rdata$')

publications_df = tibble()

for(i in files) {
  dat = readRDS(i)
  publications_df = bind_rows(publications_df,dat)
  rm(dat)
}

library(arrow)

saveRDS(publications_df, 
        'Data/openAlex_df_2000-2024.rdata')

write_feather(publications_df, 
              'Data/openAlex_df_2000-2024.feather', compression = 'zstd', compression_level = 5)

# dat_authors = publications_df %>%
#   select(work_id = id,work_title = display_name, authorships) %>%
#   unnest(cols = 'authorships',names_repair = 'unique') %>% 
#   rename(author_id = id, author_name = display_name) %>%
#   unnest(cols = 'affiliations') %>%
#   rename(inst_id = id, inst_name = display_name)


# The core of the work is to process the 'authorships' list-column.
# We'll create a new set of columns with author and institution statistics.
processed_data <- publications_df %>% slice_sample(n=10) %>%
  # Add a unique publication number for easy reference, similar to pubNum in the Rmd
  mutate(pubNum = row_number(), work_id = clean_id(id)) %>%
  select(-id) %>%
  # Create a new column that processes the authorships for each paper
  mutate(
    # 'map' iterates through the 'authorships' column for each publication
    author_stats = map(authorships, function(authors_df) {
      
      # If there are no authors, return an empty summary
      if (is.null(authors_df) || nrow(authors_df) == 0) {
        return(
          tibble(
            nAuthors = 0, nIndAuth = 0, nSwissAuth = 0, nBothAuth = 0,
            nIndInst = 0, nSwissInst = 0, nCountries = 0
          )
        )
      }
      
      # Unnest the affiliations for each author. This is the key step.
      # Each row will now be one author affiliated with one institution for that paper.
      author_inst <- authors_df %>%
        select(author_id = id, author_name = display_name, affiliations) %>%
        unnest(affiliations, keep_empty = TRUE) %>%
        rename(inst_id = id) %>%
        select(author_id, author_name, inst_name = display_name, inst_id, country_code)
      
      # For each author on the paper, find all their unique country codes
      author_countries <- author_inst %>%
        group_by(author_id, author_name) %>%
        summarise(
          countries = list(unique(country_code)),
          .groups = 'drop'
        ) %>%
        # Categorize each author based on their affiliations for this paper
        mutate(
          is_swiss = map_lgl(countries, ~ "CH" %in% .x),
          is_indian = map_lgl(countries, ~ "IN" %in% .x),
          auth_cat = case_when(
            is_swiss & is_indian ~ "Both",
            is_swiss ~ "Swiss",
            is_indian ~ "India",
            TRUE ~ "Other"
          )
        )
      
      # Calculate the summary statistics for the single publication
      tibble(
        nAuthors = n_distinct(author_countries$author_id),
        nIndAuth = sum(author_countries$auth_cat == "India"),
        nSwissAuth = sum(author_countries$auth_cat == "Swiss"),
        nBothAuth = sum(author_countries$auth_cat == "Both"),
        nIndInst = n_distinct(author_inst$inst_name[author_inst$country_code == "IN"], na.rm = TRUE),
        nSwissInst = n_distinct(author_inst$inst_name[author_inst$country_code == "CH"], na.rm = TRUE),
        nCountries = n_distinct(author_inst$country_code, na.rm = TRUE)
      )
    }),
    topic_info = map(topics, function(topics_df) {
      # --- Process Topic Data ---
      top_topic_info <- list( # Default empty list
        topic = tibble(id=NA, display_name=NA),
        subfield = tibble(id=NA, display_name=NA),
        field = tibble(id=NA, display_name=NA),
        domain = tibble(id=NA, display_name=NA)
      )
      
      if (!is.null(topics_df) && nrow(topics_df) > 0) {
        # The highest-ranked topic is the first one in the list
        top_topic <- topics_df %>% mutate(id = clean_id(id)) %>%
          pivot_wider(names_from = type,values_from = id:display_name, names_sep = '.') %>%
          rename(topic_rank = i,topic_class_score = score, topic.id = id.topic, subfield.id = id.subfield, field.id = id.field, domain.id = id.domain,
                 topic.name = display_name.topic, subfield.name = display_name.subfield,field.name = display_name.field,domain.name = display_name.domain) %>%
          as_tibble()
        return(top_topic)
      }
    })
  ) %>%
  # Unnest the new 'author_stats' column to make them regular columns
  unnest(author_stats) %>%
  select(-topics)

processed_data = processed_data  %>%
  select(-landing_page_url,-concepts)

ntopics = publications_df %>%
  select(id, topics, authorships) %>% 
  mutate(topics_rows = map_int(topics, function(topics_df) {nrow(topics_df)}),
         nauth = map_int(authorships, function(topics_df) {nrow(topics_df)}))

saveRDS(processed_data,file = 'openAlex_processing_partial.rdata')

# --- 4. CREATE FINAL OUTPUT FILES ---
# Recreate the two main data frames as in the RMD script

# Helper function to remove the OpenAlex URL prefix from IDs
clean_id <- function(id) {
  str_remove(id, "https://openalex.org/")
}

# 4a. paper.details: One row per publication with summary stats
paper.details <- processed_data %>%
  select(
    pubNum,
    doi,
    title,
    document_type = type,
    publication_year,
    language,
    source_title = source_display_name,
    is_oa,
    oa_status,
    cited_by_count,
    fwci,
    datasource = ids, # Using 'ids' as a stand-in for a datasource column
    # Add the newly created summary stats
    nAuthors, nIndAuth, nSwissAuth, nBothAuth, nIndInst, nSwissInst, nCountries
  ) %>%
  # Add a datasource column for consistency
  mutate(datasource = "OpenAlex")

# 4b. author.details: Contains the nested data for deeper author analysis
author.details <- processed_data %>%
  select(pubNum, datasource = ids, author_details = authorships, nAuthors:nCountries) %>%
  mutate(datasource = "OpenAlex")


# --- 5. DISPLAY AND SAVE RESULTS ---

print("--- Publication Details (paper.details) ---")
glimpse(paper.details)

print("--- Author Details (author.details) ---")
glimpse(author.details)

# You can now save these data frames for your project
# saveRDS(paper.details, file = 'Data/publication_details_from_openalex.RData')
# saveRDS(author.details, file = 'Data/author_details_from_openalex.RData')

# Or save as Feather files for cross-language use (e.g., with Python)
# library(arrow)
# write_feather(paper.details, 'Data/publication_details.feather')
# write_feather(author.details, 'Data/author_details.feather')
