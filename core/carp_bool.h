#include <stdbool.h>

// Bool
bool Bool_copy(bool* b) {
  return *b;
}

bool Bool__EQ_(bool a, bool b) {
  return a == b;
}

bool Bool__DIV__EQ_(bool a, bool b) {
  return a != b;
}
