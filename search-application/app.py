from flask import Flask, render_template, request, Response
import pandas as pd
import re
from fuzzywuzzy import fuzz
from fuzzywuzzy import process
import os

app = Flask(__name__)

import functools

@functools.lru_cache(maxsize=1)
def get_df():
    path = os.path.join("data", "publication_details.feather")
    df = pd.read_feather(path)

    # Fill NaNs early
    df = df.fillna('')

    # Downcast numerical columns
    if 'year' in df.columns:
        df['year'] = pd.to_numeric(df['year'], errors='coerce', downcast='integer')

    # Convert low-cardinality string columns to categorical
    for col in df.select_dtypes(include='object').columns:
        if df[col].nunique() < 50:
            df[col] = df[col].astype('category')

    return df

def parse_natural_query(query):
    """Parse natural language query into search parameters"""
    params = {
        'title': '',
        'authors': '',
        'abstract': '',
        'affiliations': '',
        'doi': '',
        'wos_categories': '',
        'year': ''
    }
    
    # Extract year
    year_match = re.search(r'\b(19|20)\d{2}\b', query)
    if year_match:
        params['year'] = year_match.group()
        query = re.sub(r'\b(19|20)\d{2}\b', '', query)
    
    # Check for time-related keywords
    if 'after' in query.lower() and params['year']:
        params['year'] = f">={params['year']}"
    elif 'before' in query.lower() and params['year']:
        params['year'] = f"<={params['year']}"
    
    # Extract institution names
    inst_patterns = [
        r'university of \w+',
        r'institute of \w+',
        r'\w+ university',
        r'\w+ institute'
    ]
    for pattern in inst_patterns:
        matches = re.finditer(pattern, query, re.IGNORECASE)
        for match in matches:
            params['affiliations'] += f"{match.group()} "
            query = query.replace(match.group(), '')
    
    # Look for topic-related keywords
    topic_indicators = ['about', 'regarding', 'on', 'related to']
    for indicator in topic_indicators:
        if indicator in query.lower():
            parts = query.lower().split(indicator)
            if len(parts) > 1:
                params['abstract'] = parts[1].strip()
                query = parts[0]
    
    # Remaining text could be author names or general search terms
    remaining_terms = query.strip()
    if remaining_terms:
        params['authors'] = remaining_terms
    
    return {k: v.strip() for k, v in params.items()}

@app.route('/')
def index():
    return render_template('index.html')

@app.route('/quick-search', methods=['POST'])
def quick_search():
    query = request.form.get('query', '').strip()
    params = parse_natural_query(query)
    
    df = get_df()
    mask = pd.Series([True] * len(df), index=df.index)

    for key, value in params.items():
        if not value:
            continue
            
        if key == 'year':
            if '>=' in value:
                year = int(value.replace('>=', ''))
                mask &= df['year'].astype(float) >= year
            elif '<=' in value:
                year = int(value.replace('<=', ''))
                mask &= df['year'].astype(float) <= year
            else:
                mask &= df['year'].astype(str).str.contains(value, na=False)
        elif key in ['abstract', 'title']:
            mask &= (df['abstract.s'].str.contains(value, case=False, na=False) |
                    df['abstract.w'].str.contains(value, case=False, na=False) |
                    df['article title'].str.contains(value, case=False, na=False))
        else:
            column_name = 'article title' if key == 'title' else \
                         'author full names' if key == 'authors' else \
                         key
            if column_name in df.columns:
                mask &= df[column_name].str.contains(value, case=False, na=False)
    
    filtered_df = df[mask].head(100)
    results_data = filtered_df.to_dict(orient='records')
    
    return render_template('results.html',
                         query=query,
                         results=results_data,
                         search_type="quick")

@app.route('/search', methods=['POST'])
def search():
    # Get all search parameters
    params = {
        'title': request.form.get('title', '').strip(),
        'authors': request.form.get('authors', '').strip(),
        'abstract': request.form.get('abstract', '').strip(),
        'affiliations': request.form.get('affiliations', '').strip(),
        'doi': request.form.get('doi', '').strip(),
        'wos_categories': request.form.get('wos_categories', '').strip(),
        'year_from': request.form.get('year_from', '').strip(),
        'year_to': request.form.get('year_to', '').strip()
    }

    # Start with all rows
    df = get_df()
    mask = pd.Series([True] * len(df), index=df.index)

    # Apply each non-empty parameter to the mask
    if params['title']:
        mask &= df['article title'].str.contains(params['title'], case=False, na=False)
    
    if params['authors']:
        mask &= df['author full names'].str.contains(params['authors'], case=False, na=False)
    
    if params['abstract']:
        mask &= (df['abstract.s'].str.contains(params['abstract'], case=False, na=False) |
                df['abstract.w'].str.contains(params['abstract'], case=False, na=False))
    
    if params['affiliations']:
        mask &= df['affiliations'].str.contains(params['affiliations'], case=False, na=False)
    
    if params['doi']:
        mask &= df['doi'].str.contains(params['doi'], case=False, na=False)
    
    if params['wos_categories']:
        mask &= df['wos categories'].str.contains(params['wos_categories'], case=False, na=False)
    
    # Year range filtering
    if params['year_from']:
        mask &= df['year'].astype(float) >= float(params['year_from'])
    if params['year_to']:
        mask &= df['year'].astype(float) <= float(params['year_to'])

    # Get filtered results
    filtered_df = df[mask].head(100)
    results_data = filtered_df.to_dict(orient='records')
    
    return render_template('results.html', 
                         query="Advanced Search", 
                         results=results_data, 
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
        'year_from': request.form.get('year_from', '').strip(),
        'year_to': request.form.get('year_to', '').strip()
    }

    # Start with all rows
    df = get_df()
    mask = pd.Series([True] * len(df), index=df.index)

    # Apply each non-empty parameter to the mask
    if params['title']:
        mask &= df['article title'].str.contains(params['title'], case=False, na=False)
    
    if params['authors']:
        mask &= df['author full names'].str.contains(params['authors'], case=False, na=False)
    
    if params['abstract']:
        mask &= (df['abstract.s'].str.contains(params['abstract'], case=False, na=False) |
                df['abstract.w'].str.contains(params['abstract'], case=False, na=False))
    
    if params['affiliations']:
        mask &= df['affiliations'].str.contains(params['affiliations'], case=False, na=False)
    
    if params['doi']:
        mask &= df['doi'].str.contains(params['doi'], case=False, na=False)
    
    if params['wos_categories']:
        mask &= df['wos categories'].str.contains(params['wos_categories'], case=False, na=False)
    
    # Year range filtering
    if params['year_from']:
        mask &= df['year'].astype(float) >= float(params['year_from'])
    if params['year_to']:
        mask &= df['year'].astype(float) <= float(params['year_to'])

    # Get ALL filtered results (removed .head(100))
    filtered_df = df[mask]
    csv_data = filtered_df.to_csv(index=False)
    
    timestamp = pd.Timestamp.now().strftime('%Y%m%d_%H%M%S')
    return Response(
        csv_data,
        mimetype="text/csv",
        headers={"Content-disposition": f"attachment; filename=full_results_{timestamp}.csv"}
    )

if __name__ == '__main__':
    app.run(debug=True)

app.debug = True