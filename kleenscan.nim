#[
    Kleenscan api cmdline tool
]#

import std/[parsecfg, asyncdispatch, httpclient, strutils, json, os, streams, terminal], cligen

type Scanner = ref object
    name: string
    status: string
    active: bool # True or False unfortunately
    result: string

const banner = """
       _                 __                                 
  /\ /\ | ___  ___ _ __ / _\ ___ __ _ _ __  _ __   ___ _ __ 
 / //_/ |/ _ \/ _ \ '_ \\ \ / __/ _` | '_ \| '_ \ / _ \ '__|
/ __ \| |  __/  __/ | | |\ \ (_| (_| | | | | | | |  __/ |   
\/  \/|_|\___|\___|_| |_\__/\___\__,_|_| |_|_| |_|\___|_|   
                                                            
"""

# purty colors
proc updateScreen(fScanners: seq[Scanner]) =
    eraseScreen()
    stdout.styledWriteLine(fgMagenta, banner)
    for s in fScanners:
        stdout.styledWriteLine(fgCyan, styleBright, s.name & ": ", resetStyle, if s.status == "scanning": styleBlink else: styleDim, if s.status == "scanning": fgYellow elif s.result == "Undetected": fgGreen else: fgRed, s.result)

proc kleenscan(configLocation:string = "./", file:string): string =
    ## CLI tool for scanning files with the Kleenscan API
    # parse config
    let configFile = configLocation & "kleenscan.conf"
    var f = newFileStream(configFile, fmRead)
    var p: CfgParser
    p.open(f, configFile)
    var token: string
    var fScanners: seq[Scanner]
    var section: string
    while true:
        var e = next(p)
        case e.kind
        of cfgEof: break
        of cfgSectionStart: section = e.section
        of cfgKeyValuePair:
            if section == "Token" and e.key == "token": token = e.value
            elif section == "FileScanners":
                fScanners.add(Scanner(name: e.key, active: e.value.toLowerAscii.parseBool, status: "scanning"))
        of cfgOption: discard
        of cfgError: echo e.msg
    close(p)

    # check sanity
    assert token != "", "cannot read token from " & configFile

    # Build avList string
    var avList: string = ""
    var c = fScanners.len
    for s in fScanners:
        c -= 1
        if s.active == false: continue
        if c != 0:
            avList.add(s.name & ",")
            continue
        avList.add(s.name)

    hideCursor()
    updateScreen(fScanners)

    # Post the scan request
    let scanUrl: string = "https://kleenscan.com/api/v1/file/scan"
    var mpData = newMultipartData()
    mpData.addFiles({"path":file})
    mpData.add({"avList":avList})
    var client = newAsyncHttpClient(headers = newHttpHeaders(keyValuePairs = [(key:"X-Auth-Token", val:token)]))
    var jsonResult =  parseJson(waitfor client.postContent(scanUrl, multipart=mpData))
    let scanToken = jsonResult["data"]["scan_token"].getStr()
    let resultUrl = "https://kleenscan.com/api/v1/file/result/" & scanToken

    # known issue in nim std lib where you get a protocol error on client reuse
    client = newAsyncHttpClient(headers = newHttpHeaders(keyValuePairs = [(key:"X-Auth-Token", val:token)]))

    # Poll loop
    var scanning:bool = true
    while (scanning):
        updateScreen(fScanners)
        scanning = false
        jsonResult = parseJson(waitFor client.getContent(resultUrl))
        var data = jsonResult["data"].getElems()
        for scanResp in data: # this is really expensive.... :(
            let name = (%scanResp["avname"]).getStr()
            let status = (%scanResp["status"]).getStr()
            var scanner: Scanner
            for s in fScanners:
                if s.name != name: continue
                scanner = s
            scanner.status = status
            if status == "scanning": scanning = true
            scanner.result = (%scanResp["flagname"]).getStr()
        
        # sleep 5s
        sleep(5000)
    showCursor()

proc main() =
    dispatch kleenscan

if isMainModule: main()
