zf is a simple file uploader, it is meant to be used with a server like caddy or nginx to serve the files back.

# Install
Before installing, you need to download [Zig](https://ziglang.org/download/) >= 0.11.0 on a Linux machine.

Clone the repo:
```
git clone https://github.com/Foretack/zf
```

modify `config.json`:
Field              | Description
------------------ | -------------------------------------------------------------------
`port`             | the port to listen on
`linkPrefix`       | a string that prefixes the generated file name
`absoluteSaveDir`  | the absolute path in which the uploaded files will be saved
`filenameLength`   | the length of generated file names
`maxSaveDirSizeMB` | the maximum size of the specified directory. zf will ensure that the directory never exceeds the specified amount by deleting old files
`genCharset`       | characters to use to generate file names


Build & run:
```
zig build -Doptimize=ReleaseSmall && ./zig-out/bin/zf #alternatively: ReleaseSafe ReleaseFast
```

# Usage
```
curl -v --request POST -F img=@test012345.bin zf.example.com/upload
```