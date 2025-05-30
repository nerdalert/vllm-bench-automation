#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
prompt-comparisons.py

Read vLLM benchmark JSONL (with a 'deployment' field), then for each metric
(mean_ttft_ms, mean_tpot_ms, mean_itl_ms, request_throughput) produce a grouped‐bar + table summary,
comparing all deployments, and computing how much better the best deployment
is relative to the baseline 'no-features'.
"""

import json
import argparse
import logging
from pathlib import Path
from typing import Tuple, Dict, Any

import pandas as pd
import numpy as np
import plotly.graph_objects as go
from plotly.subplots import make_subplots

# Baseline deployment to compare against
NO_FEATURES_DEPLOYMENT = "no-features"

# Metadata fields to extract from the data for display
METADATA_FIELDS = ["model", "gpu", "gateway"]

# Note: FASTER_BY_PERCENT_COL_NAME 's direct usage will be adapted for throughput
# The column header in the table will be made dynamic.
FASTER_BY_PERCENT_COL_NAME_ORIGINAL = "Faster by (%)" # Keep original for context if needed elsewhere, though we'll use dynamic names in plot

def load_data(file_name: str) -> pd.DataFrame:
    rows = []
    with open(file_name, "r", encoding="utf-8") as f:
        for lineno, line in enumerate(f, start=1):
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError as e:
                logging.warning(f"Line {lineno}: JSON parse error – skipping ({e})")
    df = pd.DataFrame(rows)
    if "deployment" not in df.columns:
        raise KeyError("Input data must include a 'deployment' field")
    for field in METADATA_FIELDS:
        if field not in df.columns:
            logging.warning(f"Metadata field '{field}' not found in data. It will be omitted from the chart display.")
    return df

def extract_metadata(df: pd.DataFrame) -> Dict[str, Any]:
    """Extracts common metadata from the first row of the DataFrame."""
    metadata = {}
    if not df.empty:
        first_row = df.iloc[0]
        for field in METADATA_FIELDS:
            metadata[field] = first_row.get(field, "N/A")
    return metadata

def compute_baseline_comparison(row: pd.Series, metric_name: str) -> Tuple[str, float]:
    """
    Given a row of deployment→value for one (num_prompts, rate) slice,
    find the best deployment (smallest for time-based, largest for throughput)
    and compute % improvement vs NO_FEATURES_DEPLOYMENT.
    """
    baseline_val = row.get(NO_FEATURES_DEPLOYMENT)

    valid_row_values = row.dropna()
    if valid_row_values.empty:
            return ("N/A", 0.0)

    is_higher_better = metric_name == "request_throughput"

    if is_higher_better:
        best_overall_deployment = valid_row_values.idxmax()
        best_overall_val = valid_row_values.max()
    else: # Lower is better (original logic for time-based metrics)
        best_overall_deployment = valid_row_values.idxmin()
        best_overall_val = valid_row_values.min()

    if pd.isna(baseline_val):
        # If baseline is N/A, report the best deployment found, but 0% improvement.
        return (best_overall_deployment, 0.0)

    percent_improvement = 0.0
    if is_higher_better:
        # For throughput: (best - baseline) / baseline * 100
        # Handle baseline_val == 0 to avoid division by zero
        if baseline_val == 0:
            percent_improvement = float('inf') if best_overall_val > 0 else 0.0
        elif best_overall_val > baseline_val: # Calculate only if there's an improvement
            percent_improvement = 100.0 * (best_overall_val - baseline_val) / baseline_val
    else: # Lower is better
        # For time: (baseline - best) / baseline * 100
        if baseline_val == 0: # Should not happen for time if it's non-zero, but defensive
            percent_improvement = 0.0 # Cannot be faster than 0
        elif best_overall_val < baseline_val: # Calculate only if there's an improvement
            percent_improvement = 100.0 * (baseline_val - best_overall_val) / baseline_val

    return (best_overall_deployment, round(percent_improvement, 2))


def plot_metric_summary(
        df: pd.DataFrame,
        metric: str,
        run_metadata: Dict[str, Any],
        export_png: bool,
        export_html: bool
):
    METRIC_LABELS = {
        "mean_ttft_ms": "Mean Time To First Token (ms)",
        "mean_tpot_ms": "Mean Time Per Output Token (ms)",
        "mean_itl_ms": "Mean Inter-Token Latency (ms)",
        "request_throughput": "Request Throughput (req/s)", # Added new metric
    }
    metric_title = METRIC_LABELS.get(metric, metric)
    is_higher_better = metric == "request_throughput"

    model_name_from_data = run_metadata.get("model", "N/A")

    metadata_display_list = []
    for key in ["gpu", "gateway"]:
        if key in run_metadata:
            metadata_display_list.append(f"{key.capitalize()}: {run_metadata[key]}")
    metadata_annotation_text = " | ".join(metadata_display_list)

    df["rate_str"] = df["request_rate"].astype(str)
    grp = (
        df
        .groupby(["num_prompts", "rate_str", "deployment"])[metric]
        .mean()
        .reset_index()
    )

    def to_numeric(r: str) -> float:
        try:
            return float(r)
        except ValueError:
            return np.inf
    grp["rate_sort"] = grp["rate_str"].map(to_numeric)
    grp = grp.sort_values(["rate_sort", "num_prompts"])

    pivot = grp.pivot(
        index=["num_prompts", "rate_str"],
        columns="deployment",
        values=metric
    )

    if NO_FEATURES_DEPLOYMENT not in pivot.columns:
        pivot[NO_FEATURES_DEPLOYMENT] = np.nan

    sorted_columns = [NO_FEATURES_DEPLOYMENT] + sorted([col for col in pivot.columns if col != NO_FEATURES_DEPLOYMENT])
    sorted_columns = [col for col in sorted_columns if col in pivot.columns]
    pivot = pivot.reindex(columns=sorted_columns)

    logging.debug(f"\n>>> Pivot table for {metric}:")
    logging.debug(pivot)

    # Pass metric to compute_baseline_comparison
    comps = pivot.apply(lambda r: compute_baseline_comparison(r, metric), axis=1)

    # Dynamic column names
    best_deployment_col_name = "Highest Throughput by" if is_higher_better else "Fastest Deployment"
    comparison_col_name = "Higher by (%)" if is_higher_better else "Faster by (%)"


    pivot[best_deployment_col_name] = comps.map(lambda x: x[0])
    pivot[comparison_col_name] = comps.map(lambda x: x[1])


    fig = make_subplots(
        rows=2, cols=1,
        row_heights=[0.65, 0.35],
        shared_xaxes=True,
        vertical_spacing=0.1,
        specs=[[{"type": "xy"}], [{"type": "table"}]]
    )

    x_vals = pivot.index.get_level_values("rate_str")
    prompts = pivot.index.get_level_values("num_prompts")

    bar_colors = ["#f8c518", "#F17322", "#D44539", "#2ca02c", "#9467bd", "#1f77b4"]

    deployments_to_plot = [col for col in pivot.columns if col not in [best_deployment_col_name, comparison_col_name]]

    for idx, deployment_name in enumerate(deployments_to_plot):
        color = bar_colors[idx % len(bar_colors)]
        fig.add_trace(
            go.Bar(
                x=x_vals,
                y=pivot[deployment_name],
                name=str(deployment_name),
                marker_color=color,
                hovertemplate=(
                    f"deployment: {deployment_name}<br>"
                    "num_prompts: %{customdata[0]}<br>"
                    "request_rate: %{x}<br>"
                    f"{metric_title}: "+"%{y:.2f}<extra></extra>"
                ),
                customdata=pd.DataFrame(prompts)
            ),
            row=1, col=1
        )

    fig.update_xaxes(
        title_text="Request Rate (requests/sec)", row=1, col=1,
        showgrid=True, gridcolor="#edebf0"
    )
    fig.update_yaxes(
        title_text=metric_title, row=1, col=1,
        showgrid=True, gridcolor="#edebf0"
    )

    chart_title = f"<b>{model_name_from_data} - {metric_title}</b>"

    fig.update_layout(
        title_text=chart_title,
        title_x=0.5,
        title_font_size=18,
        annotations=[
            go.layout.Annotation(
                text=metadata_annotation_text,
                showarrow=False,
                xref="paper", yref="paper",
                x=0.5, y=1.05,
                xanchor="center", yanchor="bottom",
                font=dict(size=12, color="DimGray")
            )
        ],
        barmode="group",
        plot_bgcolor="white",
        paper_bgcolor="white",
        legend=dict(orientation="h", yanchor="bottom", y=1.12, xanchor="center", x=0.5, title_text="Deployments:"),
        margin=dict(t=100)
    )

    table_vals = [list(x_vals), list(prompts)]
    for dep_name in deployments_to_plot:
        table_vals.append(
            [f"{v:.2f}" if not pd.isna(v) else "N/A" for v in pivot[dep_name]]
        )
    table_vals.append(pivot[best_deployment_col_name].tolist())
    table_vals.append([
        f"{v:.2f}%" if isinstance(v, (int, float)) and np.isfinite(v) else
        ("Inf%" if np.isinf(v) else "N/A")
        for v in pivot[comparison_col_name]
    ])


    headers = (
            ["Rate", "Prompts"]
            + [str(name) for name in deployments_to_plot]
            + [best_deployment_col_name, comparison_col_name] # Use dynamic names
    )

    fig.add_trace(
        go.Table(
            header=dict(
                values=[f"<b>{h}</b>" for h in headers],
                fill_color="#FED781",
                line_color="#edebf0",
                font=dict(color="#333333", size=11),
                align="center",
                height=30
            ),
            cells=dict(
                values=table_vals,
                fill_color="white",
                line_color="#edebf0",
                font=dict(color="#333333", size=10),
                align="center",
                height=25
            )
        ),
        row=2, col=1
    )

    fig.update_layout(height=900)

    if export_png:
        fname = f"summary_{metric}_{model_name_from_data.replace('/', '_')}.png"
        fig.write_image(fname, width=1200, height=900)
        logging.info(f"Exported {fname}")

    if export_html:
        fname = f"summary_{metric}_{model_name_from_data.replace('/', '_')}.html"
        html_content = fig.to_html(include_plotlyjs="cdn")
        # Markdown typically doesn't need raw tags for HTML figures
        # wrapped_html = "{% raw %}\n" + html_content + "\n{% endraw %}"
        with open(fname, 'w', encoding='utf-8') as f:
            f.write(html_content)
        logging.info(f"Exported {fname}")

    if not (export_png or export_html):
        fig.show()

def main():
    parser = argparse.ArgumentParser(
        description=f"Summarize vLLM metrics by deployment (baseline: {NO_FEATURES_DEPLOYMENT})."
    )
    parser.add_argument(
        "-f", "--file", type=Path, required=True,
        help="Input JSONL file (must include 'deployment' and metadata fields)."
    )
    parser.add_argument(
        "--export-png", action="store_true",
        help="Save plots as PNG."
    )
    parser.add_argument(
        "--export-html", action="store_true",
        help="Save plots as HTML."
    )
    parser.add_argument(
        "--debug", action="store_true",
        help="Enable debug logging including pivot tables."
    )
    args = parser.parse_args()

    log_level = logging.DEBUG if args.debug else logging.INFO
    logging.basicConfig(level=log_level, format="%(levelname)s: %(message)s")

    if not args.file.exists():
        logging.error(f"File not found: {args.file}")
        return

    df = load_data(str(args.file))
    if df.empty:
        logging.error("No data loaded; check your JSONL file.")
        return

    run_metadata = extract_metadata(df)
    if run_metadata:
        logging.info("--- Benchmark Run Metadata ---")
        for key, value in run_metadata.items():
            logging.info(f"  {key.capitalize()}: {value}")
        logging.info("------------------------------")


    deployments = sorted(df["deployment"].unique())
    logging.info(f"Loaded {len(df)} rows; Deployments found: {deployments}")
    if NO_FEATURES_DEPLOYMENT not in deployments:
        logging.warning(f"Baseline deployment '{NO_FEATURES_DEPLOYMENT}' not found in the data. Comparisons might be affected.")

    # Added "request_throughput" to the list of metrics to plot
    metrics_to_plot = ["mean_ttft_ms", "mean_tpot_ms", "mean_itl_ms", "request_throughput"]
    for metric in metrics_to_plot:
        if metric not in df.columns:
            logging.warning(f"Metric {metric} not found in data. Skipping plot.")
            continue
        logging.info(f"Plotting {metric} …")
        plot_metric_summary(
            df,
            metric,
            run_metadata=run_metadata,
            export_png=args.export_png,
            export_html=args.export_html
        )

if __name__ == "__main__":
    main()
