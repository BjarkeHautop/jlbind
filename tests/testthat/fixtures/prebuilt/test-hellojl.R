# The tests of the test client in test-prebuilt.R, which build_binary() runs
# against its pruned library.
test_that("hellojl calls its Julia code", {
  expect_equal(greet("R"), "Hello, R!")
  expect_equal(shift(c(1, 2)), c(1, 2))
  expect_equal(shift(c(1, 2), 1), c(2, 3))
  expect_error(fail("boom"), "boom")
})
