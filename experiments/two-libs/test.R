order <- commandArgs(TRUE)
a <- function() dyn.load("out/liba.so", local = TRUE, now = TRUE)
b <- function() dyn.load("out/libb.so", local = TRUE, now = TRUE)
if (identical(order, "ba")) {
  db <- b()
  da <- a()
} else {
  da <- a()
  db <- b()
}
A <- function(s, ...) .Call(getNativeSymbolInfo(s, da), ...)
B <- function(s, ...) .Call(getNativeSymbolInfo(s, db), ...)
cat("first call to", if (identical(order, "ba")) "B" else "A", "\n")
if (identical(order, "ba")) {
  print(B("libb_r_greet", "x"))
} else {
  print(A("liba_r_sum", c(1, 2)))
}
for (i in 1:200) {
  r1 <- A("liba_r_sum", as.numeric(1:10))
  r2 <- B("libb_r_greet", paste0("n", i %% 7))
  if (i %% 50 == 0) {
    A("liba_r_gc")
    B("libb_r_gc")
    gc()
  }
}
print(A("liba_r_state"))
print(r2)
print(B("libb_r_gc"))
cat("OK\n")
