document.addEventListener('DOMContentLoaded', function() {
    // ----- Form Button Behavior & Input Effects (Index Page) -----
    const forms = document.querySelectorAll('form');
    forms.forEach(form => {
        const submitBtn = form.querySelector('button[type="submit"]');
        if (submitBtn) {
            const inputs = form.querySelectorAll('input');
            inputs.forEach(input => {
                input.addEventListener('focus', function() {
                    const floating = this.closest('.form-floating');
                    if (floating) {
                        floating.classList.add('scale-105');
                    }
                });
                input.addEventListener('blur', function() {
                    const floating = this.closest('.form-floating');
                    if (floating) {
                        floating.classList.remove('scale-105');
                    }
                });
            });
            form.addEventListener('submit', function() {
                submitBtn.innerHTML = '<span class="spinner-border spinner-border-sm me-2"></span>Searching...';
                submitBtn.disabled = true;
            });
        }
    });

    // Reset submit buttons if coming from a New Search (via sessionStorage)
    if (sessionStorage.getItem('resetSearch')) {
        const submitButtons = document.querySelectorAll('button[type="submit"]');
        submitButtons.forEach(btn => {
            btn.innerHTML = btn.dataset.origText || btn.innerHTML;
            btn.disabled = false;
        });
        sessionStorage.removeItem('resetSearch');
    }

    // ----- Bootstrap Tooltip Initialization (Results Page) -----
    var tooltipTriggerList = [].slice.call(document.querySelectorAll('[data-bs-toggle="tooltip"]'));
    tooltipTriggerList.forEach(function(tooltipTriggerEl) {
        new bootstrap.Tooltip(tooltipTriggerEl);
    });

    // ----- Table Filter Functionality (Results Page) -----
    const searchInput = document.getElementById('tableSearch');
    if (searchInput) {
        const tableRows = Array.from(document.querySelectorAll('tbody tr'));
        const resultCount = document.getElementById('resultCount');
        function updateResultCount() {
            const visibleRows = tableRows.filter(row => row.style.display !== 'none').length;
            if (resultCount) {
                resultCount.textContent = `Showing ${visibleRows} results`;
            }
        }
        searchInput.addEventListener('input', function() {
            const searchTerm = searchInput.value.toLowerCase();
            tableRows.forEach(row => {
                let match = false;
                row.querySelectorAll('td').forEach(cell => {
                    const visibleText = cell.textContent.toLowerCase();
                    const fullText = (cell.dataset.fulltext || '').toLowerCase();
                    if (visibleText.includes(searchTerm) || fullText.includes(searchTerm)) {
                        match = true;
                    }
                });
                row.style.display = match ? '' : 'none';
            });
            updateResultCount();
        });
        updateResultCount();
    }

    // ----- Modal Functionality for Expandable Cells (Results Page) -----
    const detailModal = document.getElementById('detailModal');
    if (detailModal) {
        const modalBody = detailModal.querySelector('.modal-body');
        document.querySelectorAll('.expandable').forEach(cell => {
            cell.addEventListener('click', function() {
                const content = this.getAttribute('data-content');
                if (modalBody && content) {
                    modalBody.innerHTML = `<p class="lead" style="white-space: pre-line;">${content}</p>`;
                    var modal = new bootstrap.Modal(detailModal);
                    modal.show();
                }
            });
        });
    }
});

// ----- Reset Submit Buttons on Pageshow (Browser Back Button) -----
window.addEventListener('pageshow', function() {
    const submitButtons = document.querySelectorAll('button[type="submit"]');
    submitButtons.forEach(btn => {
        btn.innerHTML = btn.dataset.origText || btn.innerHTML;
        btn.disabled = false;
    });
});

// ----- Pagination Handler -----
function changePage(page) {
    const form = document.getElementById('searchForm');
    if (form) {
        let pageInput = form.querySelector('input[name="page"]');
        if (!pageInput) {
            pageInput = document.createElement('input');
            pageInput.type = 'hidden';
            pageInput.name = 'page';
            form.appendChild(pageInput);
        }
        pageInput.value = page;
        form.submit();
    }
}