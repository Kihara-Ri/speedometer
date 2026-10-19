"""Run the real iOS model/service in an isolated simulator app (no hardware fakes)."""
import argparse
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time


def run(*args, **kwargs):
    return subprocess.run(args, check=True, text=True, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", required=True, help="Booted iOS simulator UDID")
    parser.add_argument("--rail-ui", action="store_true", help="Launch the isolated interactive rail-card replay host")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    bundle = "dev.kiharari.Speedometer.RailUITests" if args.rail_ui else "dev.kiharari.Speedometer.FlowTests"
    with tempfile.TemporaryDirectory(prefix="speedometer-flow-") as temporary:
        work = Path(temporary)
        project = work / "Speedometer.xcodeproj"
        shutil.copytree(root / "Speedometer.xcodeproj", project)
        pbx = project / "project.pbxproj"
        source = pbx.read_text()
        source = re.sub(r'path = "((?:iOS|Sources)/[^";]+)"',
                        lambda match: 'path = "' + str(root / match[1]) + '"', source)
        host = "Tests/RailArrivalUI/AppDelegate.swift" if args.rail_ui else "Tests/AppFlow/AppDelegate.swift"
        source = source.replace(str(root / "iOS/Speedometer/AppDelegate.swift"), str(root / host))
        source = source.replace("INFOPLIST_FILE = iOS/Speedometer/Info.plist;", f'INFOPLIST_FILE = "{root}/iOS/Speedometer/Info.plist";')
        source = source.replace("PRODUCT_BUNDLE_IDENTIFIER = dev.kiharari.Speedometer;", f"PRODUCT_BUNDLE_IDENTIFIER = {bundle};")
        pbx.write_text(source)
        with (work / "build.log").open("w") as output:
            try:
                run("xcodebuild", "-project", str(project), "-scheme", "Speedometer",
                    "-configuration", "Debug", "-destination", f"id={args.device}",
                    "-derivedDataPath", str(work / "build"), "CODE_SIGNING_ALLOWED=NO", "build", stdout=output, stderr=subprocess.STDOUT)
            except subprocess.CalledProcessError:
                print((work / "build.log").read_text()[-12000:])
                raise
        app = work / "build/Build/Products/Debug-iphonesimulator/Speedometer.app"
        run("xcrun", "simctl", "install", args.device, str(app))
        container = Path(run("xcrun", "simctl", "get_app_container", args.device, bundle, "data", capture_output=True).stdout.strip())
        result_name = "rail-ui-checks.json" if args.rail_ui else "flow-result.json"
        result = container / "Documents" / result_name
        result.unlink(missing_ok=True)
        run("xcrun", "simctl", "privacy", args.device, "grant", "location", bundle)
        run("xcrun", "simctl", "launch", "--terminate-running-process", args.device, bundle)
        try:
            for _ in range(200):
                if result.exists():
                    report = json.loads(result.read_text())
                    print(json.dumps(report, ensure_ascii=False, indent=2))
                    if report["failure"]:
                        raise SystemExit(1)
                    if args.rail_ui:
                        print(f"Interactive replay ready; result: {container / 'Documents/rail-ui-result.json'}")
                    return
                time.sleep(0.1)
            raise SystemExit("No flow test result from simulator")
        finally:
            if not args.rail_ui:
                run("xcrun", "simctl", "terminate", args.device, bundle)


if __name__ == "__main__":
    main()
