// Selects the symgc collector in a program that does not take --DRT- options
// (the druntime unit test runner takes module names as arguments, and the
// runtime reads DRT_ environment variables only when a program opts in).
extern(C) __gshared string[] rt_options = ["gcopt=gc:sdcq"];
