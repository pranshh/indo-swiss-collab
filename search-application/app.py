from flask import Flask, render_template, request, Response
from sentence_transformers import SentenceTransformer
import torch
import duckdb
import pandas as pd
import re
import os

app = Flask(__name__)
DATA_PATH = os.path.join("data", "publication_details.parquet")
RESULTS_PER_PAGE = 20  # Show 20 results per page

model = SentenceTransformer('paraphrase-MiniLM-L3-v2')

QUERY_PATTERNS = {
    'year_query': [
        "papers from year",
        "published in year",
        "research after year",
        "publications before year",
    ],
    'topic_query': [
        "research about topic",
        "papers on subject",
        "articles about field",
        "studies regarding topic",
    ],
    'author_query': [
        "papers by author",
        "research from author",
        "publications by researcher",
    ],
    'affiliation_query': [
        "research from university",
        "papers from institute",
        "publications from institution",
    ]
}

def get_query_type(query):
    # Encode user query
    query_embedding = model.encode(query, convert_to_tensor=True)
    
    best_score = -1
    best_type = None
    
    # Compare with each pattern
    for query_type, patterns in QUERY_PATTERNS.items():
        pattern_embeddings = model.encode(patterns, convert_to_tensor=True)
        similarity_scores = torch.nn.functional.cosine_similarity(query_embedding.unsqueeze(0), pattern_embeddings)
        max_score = torch.max(similarity_scores).item()
        
        if max_score > best_score:
            best_score = max_score
            best_type = query_type
    
    return best_type if best_score > 0.5 else None

def parse_natural_query(query):
    params = {
        'title': '',
        'authors': '',
        'abstract': '',
        'affiliations': '',
        'wos_categories': '',
        'year': ''
    }

    # Get query type using BERT
    query_type = get_query_type(query)

    # Extract information based on query type
    if query_type == 'year_query':
        year_match = re.search(r'(\d{4})', query)
        if year_match:
            year = year_match.group(1)
            if 'after' in query.lower() or 'since' in query.lower():
                params['year'] = f">={year}"
            elif 'before' in query.lower() or 'until' in query.lower():
                params['year'] = f"<={year}"
            else:
                params['year'] = f"={year}"
    
    elif query_type == 'topic_query':
        for indicator in ['about', 'on', 'regarding', 'concerning']:
            if indicator in query.lower():
                topic = query.lower().split(indicator)[-1].strip()
                params['abstract'] = topic
                break
    
    elif query_type == 'author_query':
        for indicator in ['by', 'from']:
            if indicator in query.lower():
                author = query.lower().split(indicator)[-1].strip()
                params['authors'] = author
                break
    
    elif query_type == 'affiliation_query':
        for indicator in ['from', 'at']:
            if indicator in query.lower():
                inst = query.lower().split(indicator)[-1].strip()
                params['affiliations'] = inst
                break

    # If no specific type matched, try general extraction
    if not any(params.values()):
        remaining = query.strip()
        if len(remaining.split()) > 2:
            params['abstract'] = remaining
        else:
            params['authors'] = remaining

    return {k: v.strip() for k, v in params.items() if v.strip()}

torch.set_num_threads(1)
torch.set_grad_enabled(False)

def build_duckdb_query(params, limit=True, page=1, per_page=20):
    try:
        conditions = []
        if params.get('year'):
            if 'BETWEEN' in str(params['year']):
                conditions.append(f""""year" {params['year']}""")
            elif params['year'].startswith('>=') or params['year'].startswith('<=') or params['year'].startswith('='):
                conditions.append(f""""year" {params['year']}""")

        if params.get('title'):
            conditions.append(f"""lower("article title") LIKE '%{params['title'].lower()}%'""")
        if params.get('authors'):
            conditions.append(f"""lower("author full names") LIKE '%{params['authors'].lower()}%'""")
        if params.get('abstract'):
            conditions.append(
                f"""(lower("abstract.s") LIKE '%{params['abstract'].lower()}%' OR 
                    lower("abstract.w") LIKE '%{params['abstract'].lower()}%')"""
            )

        where_clause = "WHERE " + " AND ".join(conditions) if conditions else ""
        
        # Add pagination with offset
        offset = (page - 1) * per_page if page > 1 else 0
        
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
                "wos categories",
                "year",
                COUNT(*) OVER() as total_count
            FROM read_parquet('{DATA_PATH}')
            {where_clause}
        )
        SELECT * FROM filtered_results
        """
        
        if limit:
            query += f" LIMIT {per_page} OFFSET {offset}"
        
        return query
    except Exception as e:
        print(f"Query build error: {e}")
        return None
    
@app.route('/')
def index():
    return render_template('index.html')

@app.route('/quick-search', methods=['POST'])
def quick_search():
    try:
        query = request.form.get('query', '').strip()
        if not query:
            return render_template('results.html',
                                query="",
                                results=[],
                                search_type="quick",
                                error="Please enter a search query")

        # Get the filter preference from the dropdown
        filter_by = request.form.get('filter_by', '').strip().lower()
        
        # First, try to parse the natural language query
        params = parse_natural_query(query)
        
        # If the user selected a filter, override the parsed params to search in only that field.
        if filter_by:
            if filter_by == 'title':
                params = {'title': query}
            elif filter_by == 'abstract':
                params = {'abstract': query}
            elif filter_by == 'keywords':
                params = {'wos_categories': query}
        
        sql_query = build_duckdb_query(params, limit=True)
        
        if not sql_query:
            return render_template('results.html',
                                query=query,
                                results=[],
                                search_type="quick",
                                error="Error building query")
        
        try:
            df = duckdb.query(sql_query).df()
            if df is None or df.empty:
                return render_template('results.html',
                                    query=query,
                                    results=[],
                                    search_type="quick",
                                    error="No results found")
                
            results_data = df.to_dict(orient='records')
            return render_template('results.html',
                                query=query,
                                results=results_data,
                                search_type="quick",
                                search_terms=params)
        except Exception as e:
            print(f"Query execution error: {e}")
            return render_template('results.html',
                                query=query,
                                results=[],
                                search_type="quick",
                                error=f"Error executing search: {str(e)}")
    except Exception as e:
        print(f"General error: {e}")
        return render_template('results.html',
                            query=query if 'query' in locals() else "",
                            results=[],
                            search_type="quick",
                            error=f"An error occurred: {str(e)}")

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
        
        # Year handling
        year_from = request.form.get('year_from', '').strip()
        year_to = request.form.get('year_to', '').strip()
        if year_from and year_to:
            params['year'] = f"BETWEEN {year_from} AND {year_to}"
        elif year_from:
            params['year'] = f">= {year_from}"
        elif year_to:
            params['year'] = f"<= {year_to}"

        sql_query = build_duckdb_query(params, limit=True, page=page, per_page=20)
        if not sql_query:
            return render_template('results.html',
                                query="Advanced Search",
                                results=[],
                                error="Error building query")

        df = duckdb.query(sql_query).df()
        if df.empty:
            return render_template('results.html',
                                query="Advanced Search",
                                results=[],
                                error="No results found")

        # Get total count from the first row
        total_count = df['total_count'].iloc[0] if 'total_count' in df.columns else len(df)
        total_pages = (total_count + 19) // 20  # Ceiling division by 20

        # Remove total_count column before sending to template
        if 'total_count' in df.columns:
            df = df.drop('total_count', axis=1)

        results_data = df.to_dict(orient='records')
        return render_template('results.html',
                            query="Advanced Search",
                            results=results_data,
                            total_count=total_count,
                            current_page=page,
                            total_pages=total_pages,
                            search_type="advanced",
                            search_terms=params)

    except Exception as e:
        print(f"Search error: {e}")
        return render_template('results.html',
                            query="Advanced Search",
                            results=[],
                            error=str(e))
        
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