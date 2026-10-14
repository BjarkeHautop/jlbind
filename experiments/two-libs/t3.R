d <- dyn.load("out/combined.so", local = TRUE, now = TRUE)
C <- function(s, ...) .Call(getNativeSymbolInfo(s, d), ...)
for (i in 1:200) {
  r1 <- C("liba_r_sum", as.numeric(1:10))
  r2 <- C("libb_r_greet", paste0("n", i %% 7))
  if (i %% 50 == 0) {
    C("liba_r_gc")
    C("libb_r_gc")
    gc()
  }
}
print(C("liba_r_state"))
print(r2)
cat("OK\n")
