new_counter <- function(start = 0) .Call(C_new_counter, start)
increment <- function(counter, by = 1) .Call(C_increment, counter, by)
counters <- function(n) .Call(C_counters, n)
live <- function() .Call(C_live)
