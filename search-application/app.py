from flask import Flask, render_template, request, Response
import pandas as pd
import re
import os

app = Flask(__name__)
DATA_PATH = os.path.join("data", "publication_details.feather")
RESULTS_PER_PAGE = 100

df_publications = pd.read_feather(DATA_PATH)

def parse_natural_query(query):
    params = {
        'title': '',
        'authors': '',
        'abstract': '',
        'affiliations': '',
        'doi': '',
        'wos_categories': '',
        'year': ''
    }

    year_match = re.search(r'\b(19|20)\d{2}\b', query)
    if year_match:
        params['year'] = year_match.group()
        query = re.sub(r'\b(19|20)\d{2}\b', '', query)

    if 'after' in query.lower() and params['year']:
        params['year'] = f">={params['year']}"
    elif 'before' in query.lower() and params['year']:
        params['year'] = f"<={params['year']}"

    # Extract institutions
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

    # Extract topics
    topic_indicators = ['about', 'regarding', 'on', 'related to']
    for indicator in topic_indicators:
        if indicator in query.lower():
            parts = query.lower().split(indicator)
            if len(parts) > 1:
                params['abstract'] = parts[1].strip()
                query = parts[0]

    # Remaining text is treated as author names
    remaining_terms = query.strip()
    if remaining_terms:
        params['authors'] = remaining_terms

    return {k: v.strip() for k, v in params.items()}

def filter_dataframe(params):
    df = df_publications.copy()
    if params.get('title'):
        df = df[df['article title'].str.contains(params['title'], case=False, na=False)]
    if params.get('authors'):
        mask1 = df['author full names'].str.contains(params['authors'], case=False, na=False)
        mask2 = df['authors'].str.contains(params['authors'], case=False, na=False)
        df = df[mask1 | mask2]
    if params.get('abstract'):
        mask1 = df['abstract.s'].str.contains(params['abstract'], case=False, na=False)
        mask2 = df['abstract.w'].str.contains(params['abstract'], case=False, na=False)
        mask3 = df['article title'].str.contains(params['abstract'], case=False, na=False)
        df = df[mask1 | mask2 | mask3]
    if params.get('affiliations'):
        df = df[df['affiliations'].str.contains(params['affiliations'], case=False, na=False)]
    if params.get('doi'):
        df = df[df['doi'].str.contains(params['doi'], case=False, na=False)]
    if params.get('year'):
        year_val = params['year']
        if 'BETWEEN' in year_val:
            parts = year_val.replace('BETWEEN', '').split('AND')
            if len(parts) == 2:
                start, end = int(parts[0]), int(parts[1])
                df = df[(df['year'] >= start) & (df['year'] <= end)]
        elif year_val.startswith('>='):
            df = df[df['year'] >= int(year_val[2:].strip())]
        elif year_val.startswith('<='):
            df = df[df['year'] <= int(year_val[2:].strip())]
        else:
            try:
                df = df[df['year'] == int(year_val)]
            except ValueError:
                pass
    return df

@app.route('/')
def index():
    return render_template('index.html')

@app.route('/quick-search', methods=['POST'])
def quick_search():
    query = request.form.get('query', '').strip()
    params = parse_natural_query(query)
    df = filter_dataframe(params)
    results_data = df.head(RESULTS_PER_PAGE).to_dict(orient='records')
    if df.empty:
        return render_template('results.html',
                              query=query,
                              results=[],
                              message="No results found.",
                              search_type="quick")
    return render_template('results.html',
                         query=query,
                         results=results_data,
                         total_count=len(df),
                         current_page=1,
                         total_pages=(len(df) + RESULTS_PER_PAGE - 1) // RESULTS_PER_PAGE,
                         search_type="quick")

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

if __name__ == '__main__':
    app.run()