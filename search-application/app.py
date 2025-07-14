from flask import Flask, render_template, request, Response
import pandas as pd
import re
import os

app = Flask(__name__)
DATA_PATH = os.path.join("data", "publication.parquet")
RESULTS_PER_PAGE = 100

df_publications = pd.read_parquet(DATA_PATH)

def filter_dataframe(params):
    df = df_publications.copy()

    if params.get('title'):
        df = df[df['title'].str.contains(params['title'], case=False, na=False)]

    if params.get('authors'):
        df = df[df['author_names'].str.contains(params['authors'], case=False, na=False)]

    if params.get('abstract'):
        df = df[df['abstract'].str.contains(params['abstract'], case=False, na=False)]

    if params.get('affiliations'):
        df = df[df['host_organization_name'].str.contains(params['affiliations'], case=False, na=False)]

    if params.get('abstract'):
        df = df[df['abstract'].str.contains(params['abstract'], case=False, na=False)]

    if params.get('year'):
        year_val = params['year']
        if 'BETWEEN' in year_val:
            parts = year_val.replace('BETWEEN', '').split('AND')
            if len(parts) == 2:
                start, end = int(parts[0]), int(parts[1])
                df = df[(df['publication_year'] >= start) & (df['publication_year'] <= end)]
        elif year_val.startswith('>='):
            df = df[df['publication_year'] >= int(year_val[2:].strip())]
        elif year_val.startswith('<='):
            df = df[df['publication_year'] <= int(year_val[2:].strip())]
        else:
            try:
                df = df[df['publication_year'] == int(year_val)]
            except ValueError:
                pass

    return df

@app.route('/')
def index():
    return render_template('index.html')

@app.route('/search', methods=['POST'])
def search():
    try:
        page = int(request.form.get('page', 1))
        params = {
            'title': request.form.get('title', '').strip(),
            'authors': request.form.get('authors', '').strip(),
            'abstract': request.form.get('abstract', '').strip(),
            'affiliations': request.form.get('affiliations', '').strip(),
            'doi': request.form.get('doi', '').strip(),
            'wos_categories': request.form.get('wos_categories', '').strip(),
            'year': ''
        }
        
        year_from = request.form.get('year_from', '').strip()
        year_to = request.form.get('year_to', '').strip()
        if year_from and year_to:
            params['year'] = f"BETWEEN {year_from} AND {year_to}"
        elif year_from:
            params['year'] = f">= {year_from}"
        elif year_to:
            params['year'] = f"<= {year_to}"

        df = filter_dataframe(params)
        total_count = len(df)
        total_pages = (total_count + RESULTS_PER_PAGE - 1) // RESULTS_PER_PAGE
        start = (page - 1) * RESULTS_PER_PAGE
        end = start + RESULTS_PER_PAGE
        results_data = df.iloc[start:end].to_dict(orient='records')
        start_index = start + 1 if total_count > 0 else 0
        end_index = min(end, total_count)

        if df.empty:
            return render_template('results.html',
                                query="Advanced Search",
                                results=[],
                                total_count=0,
                                current_page=page,
                                total_pages=0,
                                message="No results found.",
                                search_type="advanced")

        return render_template('results.html',
                            query="Advanced Search",
                            results=results_data,
                            total_count=total_count,
                            current_page=page,
                            total_pages=total_pages,
                            start_index=start_index,
                            end_index=end_index,
                            search_type="advanced")

    except Exception as e:
        return render_template('results.html',
                            query="Advanced Search",
                            results=[],
                            error=str(e),
                            search_type="advanced")
    
@app.route('/download', methods=['POST'])
def download():
    params = {
        'title': request.form.get('title', '').strip(),
        'authors': request.form.get('authors', '').strip(),
        'abstract': request.form.get('abstract', '').strip(),
        'affiliations': request.form.get('affiliations', '').strip(),
        'doi': request.form.get('doi', '').strip(),
        'wos_categories': request.form.get('wos_categories', '').strip(),
        'year': ''
    }
    
    year_from = request.form.get('year_from', '').strip()
    year_to = request.form.get('year_to', '').strip()
    if year_from and year_to:
        params['year'] = f"BETWEEN {year_from} AND {year_to}"
    elif year_from:
        params['year'] = f">= {year_from}"
    elif year_to:
        params['year'] = f"<= {year_to}"

    df = filter_dataframe(params)
    csv_data = df.to_csv(index=False)
    timestamp = pd.Timestamp.now().strftime('%Y%m%d_%H%M%S')
    return Response(
        csv_data,
        mimetype="text/csv",
        headers={"Content-disposition": f"attachment; filename=results_{timestamp}.csv"}
    )

@app.route('/about')
def about():
    return render_template('about.html')

if __name__ == '__main__':
    app.run()