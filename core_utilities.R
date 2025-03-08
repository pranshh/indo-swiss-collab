rm.sinks = function() {
  x = sink.number()
  if(x>0) {
    for (i in 1:x) {
      sink(file=NULL)
    }
  }
  
}

#A function to load required libraries
using<-function(...) {
  libs<-unlist(list(...))
  req<-suppressMessages(unlist(lapply(libs,require,character.only=TRUE))) #suppressMessages
  need<-libs[req==FALSE]
  if(length(need)>0){ 
    install.packages(need,dependencies = TRUE)
    lapply(need,require,character.only=TRUE)
  }
}

printo = function(...) cat(paste0(...,'  \n'))

#To extract the first unique value from a vector, for uploading to JSON.
#If it is NA, then return an empty string.
val1.j = function(x) {
  y = unique(x)[1]
  return(ifelse(is.na(y),'',y))
}

#Get a choice from user
get.choice = function(prompt = 'Continue? (y/n): ', choices = c('y','n'), stop = NA) {
  x = ''
  choices = tolower(choices)
  while (!(x %in% choices)) {
    x = tolower(readline(prompt = prompt)) %>% str_trim() %>% str_sub(1,1)
  }
  if(!is.na(stop) & x %in% stop) stop("\n User aborted")
  return(x)
}

get.date = function(prompt = 'Enter date: ') {
  date.choose = NA
  x = readline(prompt = prompt) %>% str_trim()
  x = suppressWarnings(ymd(x))
  while(is.na(x)) {
    x = readline('Please enter a valid date: ')
    x = suppressWarnings(ymd(x))
  }
  return(x)
}

#Get an integer from user. Return NA if the input is 'q'
get.integer = function(prompt = 'Number: ', range = c(0,2^20), stop = 'q') {
  x = NA
  x = readline(prompt = prompt) %>% str_trim()
  if(tolower(x) %in% stop) return(NA)
  x = suppressWarnings(as.integer(x))
  while (is.na(x) | (x < range[1] | x > range[2])) {
    printo('Please enter a number between ',range[1],' and ',range[2])
    x = readline(prompt = prompt) %>% str_trim()
    if(tolower(x) %in% stop) return(NA)
    x =  as.integer(x)
  }
  return(x)
}

#Get a time from the user. Return NA if the input is 'q'
get.time = function(prompt = 'Time (24h format): ', stop = 'q') {
  x = NA
  x = suppressWarnings(readline(prompt = prompt) %>% str_trim())
  if(tolower(x) %in% stop) return(NA)
  x = str_remove_all(x,'[^\\d]')
  while (is.na(x) | !(str_length(x) == 4 & as.numeric(str_sub(x,1,2)) <= 24 & as.numeric(str_sub(x,3,4)) <= 59)) {
    printo('Please enter a time formatted for 24H.')
    x = readline(prompt = prompt) %>% str_trim()
    if(tolower(x) %in% stop) return(NA)
    x = str_remove_all(x,'[^\\d]')
  }
  return(x)
}

get_recent_files <- function(folder_path, pattern = NULL) {
  # Get list of files in the folder
  file_list <- list.files(path = folder_path, 
                          full.names = T, 
                          pattern = get0('pattern'), all.files = F)
  
  # Get file modification times
  mod_times <- file.info(file_list)$mtime
  
  # Sort files by modification time (most recent first)
  sorted_files <- file_list[order(mod_times, decreasing = TRUE)]
  
  # Return the 5 most recently modified files
  return(head(sorted_files, n = 5))
}


jsoncontent = function(x) {
  return(fromJSON(content(x,as = 'text', encoding = 'UTF-8'),simplifyVector = F))
}

avoidnull = function(x) {
  ifelse(is.null(x),'',x)
}

#Check if user wants to continue
check.continue = function(msg='',prompt = 'Continue? (Y/N): ') {
  x = 'k'
  while (!(x %in% c('y','n'))) {
    x = tolower(readline(prompt = prompt)) %>% str_trim() %>% str_sub(1,1)
  }
  
  if(x == 'n') {
    stop(paste("\n User aborted",msg))}
}

# Interfaces with Google Sheets -------------------------------------------

#find contiguous ranges
consecutive_ranges = function(a) {
  if(anyDuplicated(a)) stop('consecutive_ranges cannot have duplicated inputs.')
  n = length(a)
  if(n == 0) return(NA)
  if(n == 1) return(matrix(a[1],ncol = 2))
  a = sort(a)
  consec_diff = a[-1] - a[-n]
  cuts = which(consec_diff > 1)
  cuts = c(min(a)-0.1,a[cuts]+0.1,max(a))
  grps = cut(a,breaks = cuts,labels = F)
  out = matrix(0,ncol = 2,nrow=max(grps))
  for(i in 1:max(grps)) {
    out[i,1] = min(a[grps==i])
    out[i,2] = max(a[grps==i])
  }
  return(out)
}

#wrapper around range_delete for deleting rows
delete_rows = function(rownums,ss,sheet,verbose = T) {
  #Ensure rownums are only numbers and not empty
  if(!is.numeric(rownums)) stop('rownums input to delete_rows should be numeric')
  if(length(rownums) == 0) stop('rownums input to delete_rows not be empty')
  rownums = unique(rownums)
  rowgrps = consecutive_ranges(rownums)
  if(verbose) printo('Making ',nrow(rowgrps),' grouped row deletions to the sheet.')
  for (row in nrow(rowgrps):1) {
    rowmin = rowgrps[row,1]
    rowmax = rowgrps[row,2]
    if(verbose) printo('Removing rows ',rowmin,' to ',rowmax)
    range_delete(ss= ss,
                 sheet = sheet,
                 range = cell_rows(rowmin:rowmax))
  }
  printo('Rows removed')
}

#wrapper around range_write
edit_sheet = function(newdata, #data frame with columns that are named x[colnum] instead of A1 notation
                      ## First column is called rownum that has actual row number on sheet
                      ss, 
                      sheet, verbose = F) {
  #Ensure rownames are correct
  x = names(newdata) 
  if(sum(x == 'rownum') != 1) {stop('rownum column is missing or duplicated in input to edit_sheet')}
  x = x[which(x!='rownum')]
  if(!all(grepl('^x\\d+',x))) {stop('column numbers not correctly provided in input to edit_sheet')}
  #Ensure there are no duplicate rows
  if(any(duplicated(newdata$rownum))) {stop('Duplicate rownumber values provided to edit_sheet. Function has failed.')}
  
  #Identify all the contiguous sets of rows in newdata
  rowgrps = consecutive_ranges(newdata$rownum)
  #Identify all the contiguous sets of columns in newdata
  colgrps = consecutive_ranges(names(newdata %>% select(-rownum)) %>% str_remove('^x') %>% as.numeric())
  #Report
  if(verbose) printo('Making ',nrow(colgrps)*nrow(rowgrps),' grouped edits to the sheet.')
  for (col in 1:nrow(colgrps)) {
    for (row in 1:nrow(rowgrps)) {
      rlim = list(
        rowmin = rowgrps[row,1],rowmax = rowgrps[row,2],
        colmin = colgrps[col,1],colmax = colgrps[col,2]
      )
      writdat = newdata %>% filter(rownum>= rlim$rowmin& rownum<=rlim$rowmax) %>% select(-rownum) %>%
        select(any_of(str_c('x',c(rlim$colmin:rlim$colmax))))
      
      range_write(ss = ss,
                  sheet = sheet,
                  data = writdat,
                  range = cell_limits(ul=c(rlim$rowmin,rlim$colmin),
                                      lr=c(rlim$rowmax,rlim$colmax)),
                  col_names = F,
                  reformat = F)
    }
  }
  printo('Edits complete')
}


get_gs4_sheetname = function(searchStr, ss) {
  sheetname = NA
  while(is.na(sheetname)) {
    n = gs4_get(ss = ss)#$sheets$name
    sheetname = searchStr
    sheets.possible = grep(sheetname, n$sheets$name, value = T, ignore.case = T)
    if(length(sheets.possible) == 0) {
      printo('No sheet found for ',sheetname,' in ',n$name,'. Please create and then press enter to continue.')
      readline('Press enter to continue: ')
      sheetname = NA
      next
    } 
    if (length(sheets.possible) > 1) {
      printo('Multiple sheets match ',sheetname,'. Please choose which one to write data to.')
      printo(str_c(paste0(c(1:length(sheets.possible)), '. ',sheets.possible), collapse = '\n'))
      choice = get.integer('Choice: ', c(1,length(sheets.possible)))
      sheetname = sheets.possible[choice]
      rm(choice)
    } 
    if (length(sheets.possible) == 1) {
      sheetname = sheets.possible
    }
  }
  rm(sheets.possible,n)
  return(sheetname)
}

