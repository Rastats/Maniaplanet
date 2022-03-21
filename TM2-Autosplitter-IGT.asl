state("ManiaPlanet32") {}
state("ManiaPlanet") {}

startup {
    refreshRate = 0.5;

	settings.Add("SplitOnCP", false, "Split at every checkpoint");
    settings.Add("SplitOnLap", false, "Split at every lap");

    vars.loadMapName = string.Empty;

    vars.ResetVars = (Action)(() => {
        vars.startedMap = string.Empty;
        vars.currentReset = 0;
        vars.logEntries = new List<Tuple<string,int,int>>();
        vars.totalIGT = 0;
        vars.lastCP = 0;
        vars.splitNextUpdate = false;
    });

    vars.ResetVars();

    vars.GetValPtrFromSigPtr = (Func<Process, IntPtr, IntPtr>)((proc, sigPtr) => {
        if(proc.Is64Bit()) {
            int offset = 0;
            proc.ReadValue<int>(sigPtr, out offset);
            sigPtr = (IntPtr)((long)sigPtr + (long)offset + 4);
        } else
            proc.ReadPointer(sigPtr, out sigPtr);
        return sigPtr;
    });

    vars.GetRelPtrFromBase = (Func<IntPtr, IntPtr, int>)((ptr, baseAddr) => {
        return (int)((long)ptr - (long)baseAddr);
    });

    vars.timerLogTimes = (EventHandler)((s, e) => {
        if(timer.CurrentPhase == TimerPhase.Ended) {
            print("[Autosplitter] Writing log file..");
            var formatTime = (Func<int, bool, string>)((time, file) => TimeSpan.FromMilliseconds(time).ToString(file ? @"mm\.ss\.fff" : @"mm\:ss\.fff"));

            string separator = "  |  ";
            string category = timer.Run.CategoryName;
            string gameName = timer.Run.GameName;

            var filterForbidden = (Func<string, string>)(original => {
                var forbiddenChars = "<>:\"/\\|?*";
                string output = "";
                foreach(char c in original) {
                    if((int)c <= 31 || forbiddenChars.Contains(c)) { continue; }
                    output += c;
                }

                output = output.Trim();
                return output;
            });

            category = filterForbidden(category);
            gameName = filterForbidden(gameName);

            foreach(string val in timer.Run.Metadata.VariableValueNames.Values) {
                category += " - " + val;
            }
            string timesDisplay = string.Concat(gameName, " - ", category, Environment.NewLine, Environment.NewLine,
                                                "   Sum   ", separator, " Segment ", separator, "  Track", Environment.NewLine);
            
            int cumulatedTime = 0;
            foreach(Tuple<string, int, int> logTuple in vars.logEntries) {
                string map = logTuple.Item1;
                int segmentTime = logTuple.Item2;
                int retry = logTuple.Item3;
                cumulatedTime += segmentTime;
                timesDisplay += String.Format("{0}{4}{1}{4}{2}{3}\n", formatTime(cumulatedTime, false), 
                                                                      formatTime(segmentTime, false),
                                                                      map, 
                                                                      retry > 0 ? String.Format("  (Reset {0})", retry) : "",
                                                                      separator);
            }

            string base36Chars = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ";
            long minutesDateTime = (long)(DateTime.Now - new DateTime(2020, 07, 01)).TotalMinutes;
            string base36DateTime = "";
            
            while(minutesDateTime > 0) {
                base36DateTime = base36Chars[(int)(minutesDateTime % 36)] + base36DateTime;
                minutesDateTime /= 36;
            }

            string path = string.Concat(Directory.GetCurrentDirectory(), String.Format("\\TrackmaniaTimes\\{0}\\", gameName),
                                        category, "_", base36DateTime.PadLeft(5, '_'), "_", formatTime(cumulatedTime, true), ".log");
            string directoryName = Path.GetDirectoryName(path);

            if(!Directory.Exists(directoryName)) {
                Directory.CreateDirectory(directoryName);
            }

            File.AppendAllText(path, timesDisplay);
        }
    });
    timer.OnSplit += vars.timerLogTimes;

    vars.ParseMapName = (Func<string, string>)((loadMap) => {
        var isRGBHex = (Func<char, bool>)((c) => (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F'));
        string mapSlice = vars.loadMap.Current.Substring(9, vars.loadMap.Current.Length - 10);
        string output = "";
        var i = 0;
        while(i < mapSlice.Length) {
            char c = (char)mapSlice[i];
            if(c == '$') {
                if(i+3 >= mapSlice.Length) {
                    break;
                } else if(isRGBHex((char)mapSlice[i+1]) && isRGBHex((char)mapSlice[i+2]) && isRGBHex((char)mapSlice[i+3])) {
                    i += 4;
                } else {
                    i += 2;
                }
                continue;
            } else {
                output += (char)mapSlice[i];
                i += 1;
            }
        }
        return output;
    });
}

init {
    IntPtr loadingSigPtr = IntPtr.Zero;
    IntPtr raceStructSigPtr = IntPtr.Zero;
    IntPtr loadMapSigPtr = IntPtr.Zero;
    IntPtr gameInfoSigPtr = IntPtr.Zero;

    vars.loadingTarget = (game.Is64Bit())
        ? new SigScanTarget(2, "8B 05 ?? ?? ?? ?? 75 0E") //Updated
        : new SigScanTarget(9, "51 83 3D ?? ?? ?? ?? ?? A1 ?? ?? ?? ??");

    vars.raceStructTarget = (game.Is64Bit())
        ? new SigScanTarget(8, "56 48 83 EC 30 48 8B 05 ?? ?? ?? ?? 41 8B F1") //Updated
        : new SigScanTarget(38, "56 8B F1 E8 ?? ?? ?? ?? 8B 8E ?? ?? ?? ?? 85 C9 74 36");

    vars.loadMapTarget = (game.Is64Bit())
        ? new SigScanTarget(8, "7F 23 45 33 C0") //Updated
        : new SigScanTarget(59, "55 8B EC 6A FF 68 ?? ?? ?? ?? 64 A1 ?? ?? ?? ?? 50 A1 ?? ?? ?? ?? 51 33 C5 50 8D 45 F4 64 A3 ?? ?? ?? ?? 64 A1 ?? ?? ?? ??");

    vars.gameInfoTarget = (game.Is64Bit())
        ? new SigScanTarget(3, "48 89 05 ?? ?? ?? ?? 89 3D") //Updated
        : new SigScanTarget(1, "B9 ?? ?? ?? ?? E8 ?? ?? ?? ?? A1 ?? ?? ?? ?? C6 04 38 00");

    print("[Autosplitter] Scanning memory");

    IntPtr baseAddr = modules.First().BaseAddress;

    var scanner = new SignatureScanner(game, baseAddr, modules.First().ModuleMemorySize);

    if((loadingSigPtr = scanner.Scan(vars.loadingTarget)) != IntPtr.Zero)
        print("[Autosplitter] Loading Found : " + loadingSigPtr.ToString("X"));

    if((raceStructSigPtr = scanner.Scan(vars.raceStructTarget)) != IntPtr.Zero)
        print("[Autosplitter] Race State Found : " + raceStructSigPtr.ToString("X"));

    if((loadMapSigPtr = scanner.Scan(vars.loadMapTarget)) != IntPtr.Zero)
        print("[Autosplitter] LoadMap Found : " + loadMapSigPtr.ToString("X"));

    if((gameInfoSigPtr = scanner.Scan(vars.gameInfoTarget)) != IntPtr.Zero)
        print("[Autosplitter] Game Info Found : " + gameInfoSigPtr.ToString("X"));

    if(loadingSigPtr == IntPtr.Zero || raceStructSigPtr == IntPtr.Zero || loadMapSigPtr == IntPtr.Zero || gameInfoSigPtr == IntPtr.Zero)
        throw new Exception("[Autosplitter] Can't find signature");

    IntPtr loadingPtr = vars.GetValPtrFromSigPtr(game, loadingSigPtr);
    int raceStructPtr = vars.GetRelPtrFromBase(vars.GetValPtrFromSigPtr(game, raceStructSigPtr), baseAddr);
    int loadMapPtr = vars.GetRelPtrFromBase(vars.GetValPtrFromSigPtr(game, loadMapSigPtr), baseAddr);
    int gameInfoPtr = vars.GetRelPtrFromBase(vars.GetValPtrFromSigPtr(game, gameInfoSigPtr), baseAddr);

    vars.watchers = new MemoryWatcherList() {
        (vars.isLoading = new MemoryWatcher<bool>(loadingPtr)),
        (vars.raceTimer = new MemoryWatcher<int>(new DeepPointer(raceStructPtr, 0x28, 0xC8))),
        (vars.raceCP = new MemoryWatcher<int>(new DeepPointer(raceStructPtr, 0x28, 0xE0))),
        // (vars.raceResets = new MemoryWatcher<int>(new DeepPointer(raceStructPtr, 0x28, 0xD0))), // Unused
        (vars.trackCPs = new MemoryWatcher<int>(new DeepPointer(raceStructPtr, 0x28, 0xEC))),
        (vars.trackLaps = new MemoryWatcher<int>(new DeepPointer(raceStructPtr, 0x28, 0xF0))),
        (vars.raceState = new MemoryWatcher<int>(new DeepPointer(raceStructPtr, 0x28, 0xE8))),
        (vars.loadMap = new StringWatcher(new DeepPointer(loadMapPtr, 0), ReadStringType.ASCII, 128)),
        (vars.gameInfo = new StringWatcher(new DeepPointer(gameInfoPtr, 0), ReadStringType.ASCII, 128))
    };

    refreshRate = 200/3d;
}

update {
    vars.watchers.UpdateAll(game);

    if(vars.loadMap.Old != vars.loadMap.Current) {
        vars.loadMapName = vars.ParseMapName(vars.loadMap.Current);
    }

    if(vars.raceState.Old == 1 && (vars.raceState.Current == 0 || vars.raceState.Current == 2 && vars.isLoading.Current)) {
        var t = new Tuple<string, int, int>(vars.loadMapName, vars.raceTimer.Old, ++vars.currentReset);
        print("Adding log: " + t.ToString());
        vars.logEntries.Add(t);
    }
}

start {
    if(!(vars.raceState.Old == 0 && vars.raceState.Current == 1)) return false;
    
    vars.ResetVars();

    if(vars.raceTimer.Current >= 0) {
        vars.totalIGT = vars.raceTimer.Current;
    }

    print("[Autosplitter] Starting run on map " + vars.loadMapName);
    vars.startedMap = vars.loadMapName;

    return true;
}

split {
    if(vars.splitNextUpdate) {
        // Delay the split to the next update cycle, because the timer would sometimes not update immediately,
        // which made logged time be off by a few milliseconds.
        vars.splitNextUpdate = false;
        
        var t = new Tuple<string, int, int>(vars.loadMapName, vars.raceTimer.Current, vars.currentReset);
        print("Adding log: " + t.ToString());
        vars.logEntries.Add(t);

        return true;
    }

    var totalCPs = vars.trackCPs.Current * vars.trackLaps.Current;

    if(vars.raceCP.Old < vars.raceCP.Current) {
        if(vars.raceCP.Current >= totalCPs) {
            vars.currentReset = 0;
            vars.lastCP = 0;
            vars.splitNextUpdate = true;

            return false;
        }

        if(vars.raceCP.Current < totalCPs) {
            if(vars.raceCP.Current <= vars.lastCP) { return false; }
            vars.lastCP = vars.raceCP.Current;
            if(settings["SplitOnLap"] && vars.raceCP.Current >= vars.trackCPs.Current && vars.raceCP.Current % vars.trackCPs.Current == 0) {
                return true;
            }
            return settings["SplitOnCP"];
        }
    }

    return false;
}

reset {
    if(vars.loadMapName != vars.startedMap)
        return false;
    if((vars.raceState.Old == 1 && vars.raceState.Current == 0) || vars.loadMap.Changed){
        return true;
    }
    return false;
}

isLoading {
    return true;
}

gameTime {
    if(vars.raceTimer.Current > 0 && vars.raceTimer.Old < vars.raceTimer.Current) {
        int oldTimer = Math.Max (vars.raceTimer.Old, 0);
        int newTimer = Math.Max (vars.raceTimer.Current, 0);
        vars.totalIGT += (newTimer - oldTimer);
    }

    return TimeSpan.FromMilliseconds(vars.totalIGT);
}

shutdown {
    timer.OnSplit -= vars.timerLogTimes;
}
