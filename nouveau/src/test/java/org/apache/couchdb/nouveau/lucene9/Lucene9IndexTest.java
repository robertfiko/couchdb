//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package org.apache.couchdb.nouveau.lucene9;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertThrows;

import java.io.IOException;
import java.nio.file.Path;
import java.util.Collection;
import java.util.Collections;
import java.util.List;
import java.util.Map;

import org.apache.couchdb.nouveau.api.DocumentUpdateRequest;
import org.apache.couchdb.nouveau.api.DoubleField;
import org.apache.couchdb.nouveau.api.DoubleRange;
import org.apache.couchdb.nouveau.api.Field;
import org.apache.couchdb.nouveau.api.IndexDefinition;
import org.apache.couchdb.nouveau.api.SearchRequest;
import org.apache.couchdb.nouveau.api.SearchResults;
import org.apache.couchdb.nouveau.api.StringField;
import org.apache.couchdb.nouveau.core.Index;
import org.apache.couchdb.nouveau.core.IndexLoader;
import org.apache.couchdb.nouveau.core.UpdatesOutOfOrderException;
import org.apache.lucene.analysis.Analyzer;
import org.apache.lucene.index.IndexWriter;
import org.apache.lucene.index.IndexWriterConfig;
import org.apache.lucene.misc.store.DirectIODirectory;
import org.apache.lucene.search.SearcherManager;
import org.apache.lucene.store.Directory;
import org.apache.lucene.store.FSDirectory;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

public class Lucene9IndexTest {

    protected final Index setup(final Path path) throws IOException {
        final IndexDefinition indexDefinition = new IndexDefinition();
        indexDefinition.setDefaultAnalyzer("standard");
        final Index index = indexLoader().apply(path, indexDefinition);
        index.setDeleteOnClose(true);
        return index;
    }

    protected final void cleanup(final Index index) throws IOException {
        index.close();
    }

    @Test
    public void testOpenClose(@TempDir Path path) throws IOException {
        final Index index = setup(path);
        cleanup(index);
    }

    @Test
    public void testSearching(@TempDir Path path) throws IOException {
        final Index index = setup(path);
        try {
            final int count = 100;
            for (int i = 1; i <= count; i++) {
                final Collection<Field> fields = List.of(new StringField("foo", "bar", false, false));
                final DocumentUpdateRequest request = new DocumentUpdateRequest(i, null, fields);
                index.update("doc" + i, request);
            }
            final SearchRequest request = new SearchRequest();
            request.setQuery("*:*");
            final SearchResults results = index.search(request);
            assertThat(results.getTotalHits()).isEqualTo(count);
        } finally {
            cleanup(index);
        }
    }

    @Test
    public void testCounts(@TempDir Path path) throws IOException {
        Index index = setup(path);
        try {
            final int count = 100;
            for (int i = 1; i <= count; i++) {
                final Collection<Field> fields = List.of(new StringField("bar", "baz", false, true));
                final DocumentUpdateRequest request = new DocumentUpdateRequest(i, null, fields);
                index.update("doc" + i, request);
            }
            final SearchRequest request = new SearchRequest();
            request.setQuery("*:*");
            request.setCounts(List.of("bar"));
            final SearchResults results = index.search(request);
            assertThat(results.getCounts()).isEqualTo(Map.of("bar", Map.of("baz", count)));
        } finally {
            cleanup(index);
        }
    }

    @Test
    public void testRanges(@TempDir Path path) throws IOException {
        Index index = setup(path);
        try {
            final int count = 100;
            for (int i = 1; i <= count; i++) {
                final Collection<Field> fields = List.of(new DoubleField("bar", (double) i, false, true));
                final DocumentUpdateRequest request = new DocumentUpdateRequest(i, null, fields);
                index.update("doc" + i, request);
            }
            final SearchRequest request = new SearchRequest();
            request.setQuery("*:*");
            request.setRanges(Map.of("bar",
                    List.of(new DoubleRange("low", 0.0, true, (double) count / 2, true),
                            new DoubleRange("high", (double) count / 2, true, (double) count, true))));
            final SearchResults results = index.search(request);
            assertThat(results.getRanges()).isEqualTo(
                    Map.of("bar", Map.of("low", count / 2, "high", count / 2 + 1)));
        } finally {
            cleanup(index);
        }
    }

    @Test
    public void testOutOfOrder(@TempDir Path path) throws IOException {
        Index index = setup(path);
        try {
            final Collection<Field> fields = Collections.emptyList();

            // Go to 2.
            index.update("foo", new DocumentUpdateRequest(2, null, fields));

            // Should be prevented from going down to 1.
            assertThrows(UpdatesOutOfOrderException.class,
                    () -> index.update("foo", new DocumentUpdateRequest(1, null, fields)));
        } finally {
            cleanup(index);
        }
    }

    protected IndexLoader indexLoader() {
        return (path, indexDefinition) -> {
            final Analyzer analyzer = Lucene9AnalyzerFactory.fromDefinition(indexDefinition);
            final Directory dir = new DirectIODirectory(FSDirectory.open(path));
            final IndexWriterConfig config = new IndexWriterConfig(analyzer);
            config.setUseCompoundFile(false);
            final IndexWriter writer = new IndexWriter(dir, config);
            final SearcherManager searcherManager = new SearcherManager(writer, null);
            return new Lucene9Index(analyzer, writer, 0L, searcherManager);
        };
    }

}
