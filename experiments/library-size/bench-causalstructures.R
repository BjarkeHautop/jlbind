# Times CausalStructures (installed) with the library in JLBIND_LIBRARY:
#     JLBIND_LIBRARY=<jlbind.so> Rscript bench-causalstructures.R <out.csv>
# Each time is the best of 3.
suppressMessages(library(CausalStructures))
best <- function(e, n = 3) min(replicate(n, system.time(eval(e))[["elapsed"]]))
g <- uniform_dag(150, seed = 2)
cp <- generate_graph(80, p = 0.1, class = "CPDAG", seed = 1)
mag <- generate_graph(60, p = 0.08, class = "MAG", latents = 10, seed = 1)
r <- c(
  uniform_dag_150 = best(quote(uniform_dag(150, seed = 1))),
  dag_to_cpdag_150 = best(quote(dag_to_cpdag(g))),
  count_dags_x200 = best(quote(
    for (i in 1:200) {
      count_dags(cp)
    }
  )),
  mag_to_pag_x100 = best(quote(
    for (i in 1:100) {
      mag_to_pag(mag)
    }
  ))
)
write.csv(
  data.frame(task = names(r), secs = r),
  commandArgs(TRUE)[1],
  row.names = FALSE
)
