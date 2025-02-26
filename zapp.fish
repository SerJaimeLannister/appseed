#!/usr/bin/env fish

# zapp-builder.fish - A simple script to create a Zapp from an executable
# Usage: ./zapp-builder.fish [executable] [output_dir]

# Set strict error handling
set -e

function show_help
    echo "Zapp Builder - Package Linux executables into portable Zapp format"
    echo ""
    echo "Usage: ./zapp-builder.fish [executable] [output_dir]"
    echo ""
    echo "Arguments:"
    echo "  executable  - Path to the dynamically linked executable to package"
    echo "  output_dir  - Directory where the Zapp will be created (will be created if it doesn't exist)"
    echo ""
    echo "Example: ./zapp-builder.fish /usr/bin/myapp ./myapp-zapp"
end

function log
    set_color green
    echo "=> $argv"
    set_color normal
end

function error
    set_color red
    echo "ERROR: $argv" >&2
    set_color normal
    exit 1
end

# Check if we have the right number of arguments
if test (count $argv) -ne 2
    show_help
    exit 1
end

# Get and validate arguments
set executable $argv[1]
set output_dir $argv[2]

# Check if executable exists
if not test -f $executable
    error "Executable '$executable' not found"
end

# Check if executable is dynamically linked
set is_dynamic (ldd $executable 2>/dev/null | grep -v "not a dynamic executable")
if test -z "$is_dynamic"
    error "File '$executable' is not a dynamically linked executable"
end

# Create the Zapp directory structure
log "Creating Zapp directory structure in '$output_dir'"
mkdir -p $output_dir/bin
mkdir -p $output_dir/dynbin
mkdir -p $output_dir/lib

# Get the executable name
set exec_name (basename $executable)

# Create a simple static ldshim (jumploader)
log "Creating static ldshim (jumploader)"
set ldshim_c $output_dir/ldshim.c

echo '#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <libgen.h>

int main(int argc, char *argv[]) {
    char self_path[4096];
    ssize_t len = readlink("/proc/self/exe", self_path, sizeof(self_path) - 1);
    if (len == -1) {
        perror("readlink");
        return 1;
    }
    self_path[len] = \'\\0\';
    
    char *self_dir = dirname(self_path);
    
    // Construct paths
    char ld_path[4096];
    snprintf(ld_path, sizeof(ld_path), "%s/../lib/ld-linux-x86-64.so.2", self_dir);
    
    char dynbin_path[4096];
    snprintf(dynbin_path, sizeof(dynbin_path), "%s/../dynbin/'"$exec_name"'", self_dir);
    
    // Prepare arguments for execv
    char *new_argv[argc + 1];
    new_argv[0] = ld_path;
    new_argv[1] = dynbin_path;
    
    // Copy remaining arguments
    for (int i = 1; i < argc; i++) {
        new_argv[i + 1] = argv[i];
    }
    new_argv[argc + 1] = NULL;
    
    execv(ld_path, new_argv);
    perror("execv");
    return 1;
}' > $ldshim_c

# Compile the ldshim statically
log "Compiling static ldshim"
gcc -static -O2 $ldshim_c -o $output_dir/bin/$exec_name
rm $ldshim_c

# Copy the original executable to dynbin directory
log "Copying original executable to dynbin directory"
cp $executable $output_dir/dynbin/

# Get the ELF interpreter
# Fix: In Fish, we need to use a different approach for command substitution in variable assignments
begin
    set elf_interp (patchelf --print-interpreter $executable 2>/dev/null)
    if test $status -ne 0
        # If patchelf failed, try using strings method
        set elf_interp (strings $executable | head -n 1)
    end
end

log "ELF interpreter: $elf_interp"

# Copy ELF interpreter to lib directory
if test -f $elf_interp
    log "Copying ELF interpreter to lib directory"
    cp $elf_interp $output_dir/lib/
else
    error "Could not find ELF interpreter at '$elf_interp'"
end

# Find and copy all required libraries
log "Finding and copying required libraries"
set ldd_output (ldd $executable)

for line in $ldd_output
    # Parse library paths from ldd output
    if string match -q "*=>*" $line
        set lib_path (string replace -r ".*=> (.*) \(0x.*" '$1' $line)
        
        # Skip if not a real path
        if not test -f $lib_path
            continue
        end
        
        # Skip the interpreter since we already copied it
        if test "$lib_path" = "$elf_interp"
            continue
        end
        
        # Copy the library
        log "Copying '$lib_path'"
        cp $lib_path $output_dir/lib/
    end
end

# Modify rpath in the executable
log "Setting rpath in the executable"
cd $output_dir
begin
    patchelf --set-rpath '$ORIGIN/../lib' dynbin/$exec_name
    if test $status -ne 0
        log "patchelf not available, trying sed method with XORIGIN"
        patchelf --set-rpath 'XORIGIN/../lib' dynbin/$exec_name 2>/dev/null
        sed -i '0,/XORIGIN/{s/XORIGIN/$ORIGIN/}' dynbin/$exec_name
    end
end

log "Zapp created successfully in '$output_dir'"
log "To run your Zapp, execute: $output_dir/bin/$exec_name"
