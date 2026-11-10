"""Use the source-bound shipping JRE only for downloader Surefire children."""
import json
from pathlib import Path
import stat
import zipfile
import private_unit_ci as p

ARCHIVE='docker/botserver/OpenJDK17U-jre_x64_windows_hotspot_17.0.9_9.zip'
PREFIX='jdk-17.0.9+9-jre/'
MAX_MEMBER=96*1024**2


def extract(archive, destination):
    p.ordinary(archive)
    p.need(not destination.exists(), 'NATIVE_RUNTIME_DESTINATION_EXISTS')
    destination.mkdir()
    seen=set()
    expanded=0
    with zipfile.ZipFile(archive) as incoming:
        p.need(0 < len(incoming.infolist()) <= 1000, 'NATIVE_RUNTIME_MEMBER_COUNT')
        for item in incoming.infolist():
            p.need(item.filename.startswith(PREFIX) and not stat.S_ISLNK(item.external_attr >> 16),
                   'NATIVE_RUNTIME_FOREIGN_MEMBER')
            relative=item.filename[len(PREFIX):].removesuffix('/')
            if not relative:
                p.need(item.is_dir(), 'NATIVE_RUNTIME_EMPTY_FILE')
                continue
            parts=p.relative(relative)
            p.need(relative.casefold() not in seen, 'NATIVE_RUNTIME_ALIAS')
            seen.add(relative.casefold())
            target=destination.joinpath(*parts.parts)
            if item.is_dir():
                target.mkdir(parents=True,exist_ok=True)
                continue
            expanded+=item.file_size
            p.need(item.file_size <= MAX_MEMBER and expanded <= 256*1024**2, 'NATIVE_RUNTIME_EXPANSION')
            target.parent.mkdir(parents=True,exist_ok=True)
            with incoming.open(item) as source, target.open('xb') as output:
                copied=0
                while block:=source.read(65536):
                    copied+=len(block)
                    p.need(copied<=item.file_size, 'NATIVE_RUNTIME_SIZE_CHANGED')
                    output.write(block)
                p.need(copied==item.file_size, 'NATIVE_RUNTIME_SIZE_CHANGED')
    return destination/'bin/java.exe'


def prepare(source, control, result, execute):
    red=p.load_json(control/'source-manifest.json')
    rows=p.manifest(red,red['tree'])
    p.need(ARCHIVE in rows, 'SHIPPING_JRE_NOT_IN_SOURCE_CLOSURE')
    archive=source/ARCHIVE
    p.ordinary(archive)
    p.need(archive.stat().st_size==rows[ARCHIVE]['bytes'] and archive.stat().st_size<=64*1024**2,
           'SHIPPING_JRE_SIZE')
    p.need(p.digest(archive.read_bytes())==rows[ARCHIVE]['sha256'], 'SHIPPING_JRE_DIGEST')
    java=extract(archive,source.parent/'shipping-jre')
    p.ordinary(java)
    log=result/'shipping-jre-version.log'
    code=execute([str(java),'-version'],source,log,timeout=30)
    text=log.read_text(encoding='utf8',errors='replace')
    p.need(code==0 and 'version "17.0.9"' in text and '17.0.9+9' in text, 'SHIPPING_JRE_VERSION')
    proof=dict(sourceArchive=ARCHIVE,sourceBlob=rows[ARCHIVE]['git_blob'],sha256=rows[ARCHIVE]['sha256'],
               runtime='17.0.9+9',heapOption='-Xmx64m',java=str(java),versionExitCode=code)
    (result/'shipping-jre-proof.json').write_text(json.dumps(proof,indent=2),encoding='utf8')
    return java
