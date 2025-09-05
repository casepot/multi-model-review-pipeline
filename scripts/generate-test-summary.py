#!/usr/bin/env python3
"""
Generate a test summary JSON from JUnit XML and coverage JSON files.
This provides structured test context for the review pipeline.
"""

import json
import sys
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Dict, Any, Optional


def parse_junit_xml(xml_path: str) -> Dict[str, Any]:
    """Parse JUnit XML file and extract test statistics."""
    try:
        tree = ET.parse(xml_path)
        root = tree.getroot()
        
        # Handle both testsuites (root) and testsuite elements
        if root.tag == 'testsuites':
            # Aggregate stats from all test suites
            total_tests = sum(int(ts.get('tests', 0)) for ts in root.findall('testsuite'))
            total_failures = sum(int(ts.get('failures', 0)) for ts in root.findall('testsuite'))
            total_errors = sum(int(ts.get('errors', 0)) for ts in root.findall('testsuite'))
            total_skipped = sum(int(ts.get('skipped', 0)) for ts in root.findall('testsuite'))
            total_time = sum(float(ts.get('time', 0)) for ts in root.findall('testsuite'))
        else:
            # Single testsuite
            total_tests = int(root.get('tests', 0))
            total_failures = int(root.get('failures', 0))
            total_errors = int(root.get('errors', 0))
            total_skipped = int(root.get('skipped', 0))
            total_time = float(root.get('time', 0))
        
        # Calculate passed tests
        passed = total_tests - total_failures - total_errors - total_skipped
        
        # Extract test categories by analyzing classnames
        categories = {
            'unit': 0,
            'integration': 0,
            'e2e': 0,
            'other': 0
        }
        
        for testsuite in root.iter('testsuite'):
            for testcase in testsuite.findall('testcase'):
                classname = testcase.get('classname', '').lower()
                if 'unit' in classname or 'test_unit' in classname:
                    categories['unit'] += 1
                elif 'integration' in classname or 'test_integration' in classname:
                    categories['integration'] += 1
                elif 'e2e' in classname or 'end_to_end' in classname:
                    categories['e2e'] += 1
                else:
                    categories['other'] += 1
        
        # Get failure details (first 5 for brevity)
        failures = []
        for testsuite in root.iter('testsuite'):
            for testcase in testsuite.findall('testcase'):
                failure = testcase.find('failure')
                if failure is not None and len(failures) < 5:
                    failures.append({
                        'test': f"{testcase.get('classname', '')}.{testcase.get('name', '')}",
                        'message': failure.get('message', 'No message'),
                        'type': failure.get('type', 'AssertionError')
                    })
        
        return {
            'total': total_tests,
            'passed': passed,
            'failed': total_failures + total_errors,
            'skipped': total_skipped,
            'duration': round(total_time, 2),
            'categories': categories,
            'failures': failures if failures else None
        }
    except Exception as e:
        print(f"Error parsing JUnit XML: {e}", file=sys.stderr)
        return {}


def parse_coverage_json(coverage_path: str) -> Optional[float]:
    """Parse coverage JSON and extract overall coverage percentage."""
    try:
        with open(coverage_path, 'r') as f:
            coverage_data = json.load(f)
        
        # Extract overall coverage percentage
        if 'totals' in coverage_data:
            return coverage_data['totals'].get('percent_covered', None)
        
        # Alternative structure (some versions)
        if 'summary' in coverage_data:
            return coverage_data['summary'].get('percent_covered', None)
            
        return None
    except Exception as e:
        print(f"Error parsing coverage JSON: {e}", file=sys.stderr)
        return None


def generate_summary(junit_path: str, coverage_path: Optional[str], output_path: str) -> None:
    """Generate a combined test summary JSON."""
    
    # Parse JUnit results
    test_results = parse_junit_xml(junit_path)
    
    # Parse coverage if available
    coverage_percent = None
    if coverage_path and Path(coverage_path).exists():
        coverage_percent = parse_coverage_json(coverage_path)
    
    # Build summary
    summary = {
        'tests': test_results,
        'coverage': {
            'enabled': coverage_percent is not None,
            'percentage': round(coverage_percent, 1) if coverage_percent else None
        },
        'success': test_results.get('failed', 0) == 0 if test_results else False
    }
    
    # Add pass rate
    if test_results and test_results.get('total', 0) > 0:
        pass_rate = test_results.get('passed', 0) / test_results['total']
        summary['pass_rate'] = round(pass_rate, 3)
    
    # Write output
    with open(output_path, 'w') as f:
        json.dump(summary, f, indent=2)
    
    print(f"Test summary written to {output_path}")


def main():
    """Main entry point."""
    if len(sys.argv) < 3:
        print("Usage: generate-test-summary.py <junit-xml> <coverage-json> <output-json>", file=sys.stderr)
        print("       generate-test-summary.py <junit-xml> - <output-json>  # No coverage", file=sys.stderr)
        sys.exit(1)
    
    junit_path = sys.argv[1]
    coverage_path = sys.argv[2] if sys.argv[2] != '-' else None
    output_path = sys.argv[3]
    
    if not Path(junit_path).exists():
        print(f"JUnit XML file not found: {junit_path}", file=sys.stderr)
        sys.exit(1)
    
    generate_summary(junit_path, coverage_path, output_path)


if __name__ == '__main__':
    main()