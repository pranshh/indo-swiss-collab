from flask import Flask, render_template, request, Response
import duckdb
import pandas as pd
import re
import os

app = Flask(__name__)
DATA_PATH = os.path.join("data", "publication_details.parquet")
RESULTS_PER_PAGE = 20  # Show 20 results per page

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

    # Extract year with before/after handling
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

def build_duckdb_query(params, page=1, limit=True):
    conditions = []
    if params.get('title'):
        conditions.append(f"""lower("article title") LIKE '%{params['title'].lower()}%'""")
    if params.get('authors'):
        conditions.append(f"""(lower("author full names") LIKE '%{params['authors'].lower()}%' OR 
                                lower("authors") LIKE '%{params['authors'].lower()}%')""")
    if params.get('abstract'):
        conditions.append(
            f"""(lower("abstract.s") LIKE '%{params['abstract'].lower()}%' OR 
                lower("abstract.w") LIKE '%{params['abstract'].lower()}%' OR 
                lower("article title") LIKE '%{params['abstract'].lower()}%')"""
        )
    if params.get('affiliations'):
        conditions.append(f"""lower("affiliations") LIKE '%{params['affiliations'].lower()}%'""")
    if params.get('doi'):
        conditions.append(f"""lower("doi") LIKE '%{params['doi'].lower()}%'""")
    if params.get('wos_categories'):
        conditions.append(f"""lower("wos categories") LIKE '%{params['wos_categories'].lower()}%'""")
    if params.get('year'):
        if 'BETWEEN' in str(params['year']):
            conditions.append(f""""year" {params['year']}""")
        elif params['year'].startswith('>=') or params['year'].startswith('<='):
            conditions.append(f""""year" {params['year']}""")
        else:
            conditions.append(f""""year" = {params['year']}""")

    where_clause = "WHERE " + " AND ".join(conditions) if conditions else ""

    query = f"""
    WITH filtered_results AS (
        SELECT 
            "article title",
            "abstract.s",
            "abstract.w",
            "affiliations",
            "author full names",
            "authors",
            "doi",
            "scopus_link",
            "wos categories",
            "wos research areas",
            "year"
        FROM read_parquet('{DATA_PATH}')
        {where_clause}
    )
    SELECT 
        *,
        (SELECT COUNT(*) FROM filtered_results) as total_count
    FROM filtered_results
    """
        
    if limit:
        offset = (page - 1) * RESULTS_PER_PAGE
        query += f" LIMIT {RESULTS_PER_PAGE} OFFSET {offset}"
    
    return query

@app.route('/')
def index():
    return render_template('index.html')

@app.route('/quick-search', methods=['POST'])
def quick_search():
    query = request.form.get('query', '').strip()
    params = parse_natural_query(query)
    sql_query = build_duckdb_query(params, limit=True)
    df = duckdb.query(sql_query).to_df()
    results_data = df.to_dict(orient='records')
    return render_template('results.html',
                         query=query,
                         results=results_data,
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

        sql_query = build_duckdb_query(params, page=page, limit=True)
        conn = duckdb.connect(database=':memory:')
        results = conn.execute(sql_query).fetchall()
        
        if not results:
            return render_template('results.html',
                                query="Advanced Search",
                                results=[],
                                total_count=0,
                                current_page=page,
                                total_pages=0,
                                search_type="advanced")

        total_count = results[0][-1]  # Get total count from query
        total_pages = (total_count + RESULTS_PER_PAGE - 1) // RESULTS_PER_PAGE

        # Remove total_count from results
        results_data = [dict(zip(
            ['article title', 'abstract.s', 'abstract.w', 'affiliations', 
             'author full names', 'authors', 'doi', 'scopus_link', 
             'wos categories', 'wos research areas', 'year'],
            row[:-1]
        )) for row in results]

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

    sql_query = build_duckdb_query(params, limit=False)
    df = duckdb.query(sql_query).to_df()
    csv_data = df.to_csv(index=False)
    timestamp = pd.Timestamp.now().strftime('%Y%m%d_%H%M%S')
    return Response(
        csv_data,
        mimetype="text/csv",
        headers={"Content-disposition": f"attachment; filename=results_{timestamp}.csv"}
    )

if __name__ == '__main__':
    app.run(debug=True)