<?php
set_time_limit(0);
ini_set('memory_limit', '512M');

$INGEST_TOKEN = 'WYWIQAB5ICKL2VUW9PW98IYF2JMNF9XY';

$token = $_SERVER['HTTP_X_INGEST_TOKEN'] 
    ?? $_SERVER['REDIRECT_HTTP_X_INGEST_TOKEN'] 
    ?? $_POST['token'] 
    ?? $_GET['token'] 
    ?? null;

if ($token !== $INGEST_TOKEN) {
    http_response_code(403);
    echo "Forbidden\n";
    exit;
}

require __DIR__ . '/db_sql.php'; // must define $pdo

// Handle chunked upload
$chunkNum = isset($_GET['chunk']) ? (int)$_GET['chunk'] : 0;
$firstChunk = isset($_GET['first']) && $_GET['first'] == '1';
$lastChunk = isset($_GET['last']) && $_GET['last'] == '1';

$uploadDir = __DIR__ . '/epg_temp/';
if (!is_dir($uploadDir)) {
    mkdir($uploadDir, 0755, true);
}

$tempFile = $uploadDir . 'epg_upload.tmp';
$stateFile = __DIR__ . '/epg_import_state.json';

// Reset on first chunk
if ($firstChunk) {
    if (file_exists($tempFile)) {
        unlink($tempFile);
    }
    if (file_exists($stateFile)) {
        unlink($stateFile);
    }
}

// Append chunk data
$input = fopen('php://input', 'rb');
$output = fopen($tempFile, 'ab');
stream_copy_to_stream($input, $output);
fclose($input);
fclose($output);

if ($lastChunk) {
    // Process the complete file
    $result = processEpgFile($pdo, $tempFile, $stateFile);
    unlink($tempFile); // Clean up
    echo json_encode($result);
} else {
    echo json_encode(['status' => 'chunk_received', 'chunk' => $chunkNum]);
}

function processEpgFile($pdo, $xmlFile, $stateFile) {
    $limitPerChunk = 1200;
    $maxChunksPerRun = 25;
    $provider = 'silvervpn';
    
    $offset = 0;
    if (file_exists($stateFile)) {
        $state = json_decode(file_get_contents($stateFile), true);
        if (isset($state['next_offset'])) {
            $offset = (int)$state['next_offset'];
        }
    }
    
    $sql = "INSERT IGNORE INTO epg_programs 
            (epg_channel_id, provider, channel, start_time, end_time, title, description) 
            VALUES 
            (:epg_channel_id, :provider, :channel, :start_time, :end_time, :title, :description)";
    
    $insert = $pdo->prepare($sql);
    
    $totalInserted = 0;
    $totalProcessed = 0;
    $totalSkipped = 0;
    
    for ($chunk = 1; $chunk <= $maxChunksPerRun; $chunk++) {
        $reader = new XMLReader();
        if (!$reader->open($xmlFile, null, LIBXML_PARSEHUGE)) {
            return ['error' => "Could not open EPG XML file: $xmlFile"];
        }
        
        $seen = 0;
        $count = 0;
        $inserted = 0;
        $skipped = 0;
        
        while ($reader->read()) {
            if ($reader->nodeType !== XMLReader::ELEMENT || $reader->name !== 'programme') {
                continue;
            }
            
            if ($seen < $offset) {
                $seen++;
                continue;
            }
            
            if ($count >= $limitPerChunk) {
                break;
            }
            
            $epg_channel_id = (string)$reader->getAttribute('channel');
            $start_time = substr((string)$reader->getAttribute('start'), 0, 14);
            $end_time = substr((string)$reader->getAttribute('stop'), 0, 14);
            
            // Convert XML datetime to MySQL datetime format
            $start_time = date('Y-m-d H:i:s', strtotime($start_time));
            $end_time = date('Y-m-d H:i:s', strtotime($end_time));
            
            $outerXml = $reader->readOuterXML();
            $node = @simplexml_load_string($outerXml);
            
            $title = $node && isset($node->title) ? trim((string)$node->title) : '';
            $desc = $node && isset($node->desc) ? trim((string)$node->desc) : '';
            
            if ($epg_channel_id && $start_time && $title) {
                try {
                    $insert->execute([
                        ':epg_channel_id' => $epg_channel_id,
                        ':provider' => $provider,
                        ':channel' => $epg_channel_id,
                        ':start_time' => $start_time,
                        ':end_time' => $end_time,
                        ':title' => mb_substr($title, 0, 255),
                        ':description' => $desc
                    ]);
                    $inserted += $insert->rowCount();
                } catch (Throwable $e) {
                    $skipped++;
                    error_log("INSERT ERROR: " . $e->getMessage());
                }
            } else {
                $skipped++;
            }
            
            $seen++;
            $count++;
        }
        
        $reader->close();
        
        $offset += $count;
        $totalProcessed += $count;
        $totalInserted += $inserted;
        $totalSkipped += $skipped;
        
        file_put_contents($stateFile, json_encode([
            'next_offset' => $offset,
            'last_chunk_processed' => $count,
            'last_chunk_inserted' => $inserted,
            'last_chunk_skipped' => $skipped,
            'total_processed_run' => $totalProcessed,
            'total_inserted_run' => $totalInserted,
            'total_skipped_run' => $totalSkipped,
            'updated_at' => date('Y-m-d H:i:s')
        ], JSON_PRETTY_PRINT));
        
        if ($count < $limitPerChunk) {
            break;
        }
        
        sleep(5); // Small delay to prevent overwhelming the server
    }
    
    return [
        'status' => 'complete',
        'total_processed' => $totalProcessed,
        'total_inserted' => $totalInserted,
        'total_skipped' => $totalSkipped,
        'next_offset' => $offset
    ];
}
?>