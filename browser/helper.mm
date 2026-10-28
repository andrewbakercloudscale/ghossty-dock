// The browser's helper processes (pages, GPU, plugins): every
// "Ghostty Dock Helper*.app" runs this.

#include "include/cef_app.h"
#include "include/wrapper/cef_library_loader.h"

int main(int argc, char* argv[]) {
  CefScopedLibraryLoader loader;
  if (!loader.LoadInHelper()) return 1;
  CefMainArgs args(argc, argv);
  return CefExecuteProcess(args, nullptr, nullptr);
}
